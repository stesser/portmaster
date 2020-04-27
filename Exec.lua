--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019 Stefan Eßer <se@freebsd.org>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
--]]

--[[ unused - only left as working example of a coroutine
-- return an iterator usable in for loops that returns shell command result lines
-- usage: for line in shell_pipe (<shell cmd>) do ... end
local function shell_pipe (args)

   local function pp (cmd)
      local r = io.popen (cmd, "r") --  should take argument vector and environment table
      repeat
	 local line = r:read ()
	 if line then
	    coroutine.yield (line)
	 end
      until not line
      r:close ()
   end

   local function p (cmd)
      local co = coroutine.create (function () pp (cmd) end)
      return function ()
	 local code, res = coroutine.resume (co)
	 TRACE ("-->", res)
	 return res
      end
   end

   local cmd = table.concat (args, " ")
   TRACE (cmd)
   return (p (cmd))
end
--]]

-- execute shell command and return its standard output (UTIL) -- not exported !!!
-- the return value is a list with one entry per line without the trailing new-line
local function shell (args)
   local fd1r, fd1w
   local fd2r, fd2w
   if not args.to_tty then
      fd1r, fd1w = pipe ()
      fd2r, fd2w = pipe ()
   end
   local pid, errmsg = fork ()
   assert (pid, errmsg)
   if pid == 0 then
      -- child process
      if args.env then
	 for k, v in pairs (args.env) do
	    setenv (k, v)
	 end
      end
      if not args.to_tty then
	 close(fd1r)
	 dup2 (fd1w, fileno(io.stdout)) -- stdout
	 close(fd2r)
	 dup2 (fd2w, fileno(io.stderr)) -- stderr
      end
      local cmd = table.remove (args, 1)
      assert (execp (cmd, args))
      _exit (1) -- not reached ???
   end
   if args.to_tty then
      local pid, status, exitcode = wait (pid)
      TRACE ("==>", exitcode, status)
      return exitcode == 0, status
   end
   close(fd1w)
   close(fd2r) -- OK to ignore any output to stderr ???
   close(fd2w)
   local inp = fdopen (fd1r, "r")
   local result = {}
   local line = inp:read()
   while line do
      table.insert (result, line)
      line = inp:read()
   end
   inp:close()
   local pid, status, exitcode = wait (pid)
   TRACE ("==>", exitcode, status)
   if (args.table) then
      return result
   else
      return result[1]
   end
end

-- execute command according to passed flags argument
local function run (args)
   TRACE ("run", "[" .. table.concat (table.keys (args), ",") .. "]", table.unpack (args))
   if JAILBASE and args.jailed then
      table.insert (args, 1, CHROOT_CMD)
      table.insert (args, 2, JAILBASE)
      if not args.as_root and SUDO_CMD then -- chroot needs root but can then switch back to user
	 args.as_root = true
	 table.insert (args, 2, "-u")
	 table.insert (args, 3, USER)
      end
   end
   if args.as_root and SUDO_CMD then
      table.insert (args, 1, SUDO_CMD)
      if args.env then
	 for k, v in pairs (args.env) do
	    table.insert (args, 2, k .. "=" .. v)
	 end
	 args.env = nil
      end
   end
   if args.log then
      if Options.dry_run or Options.show_work then
	 local args = args
	 for i, v in ipairs (args) do
	    if string.match (v, "%s") then
	       args[i] = "'" .. v .. "'"
	    end
	 end
	 args.level = args.safe and 2 or 0
	 if Options.dry_run then
	    Msg.show {verbatim = true, "\t" .. table.concat (args, " ") .. "\n"}
	 else
	    Msg.show (args)
	 end
      end
   end
   if Options.dry_run and not args.safe then
      return args.table and {} or "" -- dummy return value for --dry-run
   end
   return shell (args)
end

-- run make command
local function make (args)
   table.insert (args, 1 , MAKE_CMD)
   --local result = shell (args)
   local result = run (args)
   if result then
      if args.split then
	 result = split_words (result)
      end
      if result == "" then
	 result = nil
      end
   end
   return result
end

-- execute and log a package command that does not modify any state (JAILED)
function pkg (args)
   if args.jailed then
      if JAILBASE then
	 table.insert (args, 1, "-c")
	 table.insert (args, 2, JAILBASE)
      end
      args.jailed = nil
   end
   if Options.developer_mode then
      table.insert (args, 1, "--debug")
   end
   table.insert (args, 1, PKG_CMD)
   --return shell (args)
   return run (args)
end

--
return {
   make = make,
   pkg = pkg,
   run = run,
}
