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

-- ----------------------------------------------------------------------------------
-- print command if at least one of dry-run or show-work is set
local function log (level, ...)
   local args = {...}
   for i = 1, #args do
      args[i] = tostring(args[i])
   end
   local text = table.concat (args, " ")
   if level <= Msg.level then
      if Options.dry_run then
	 stdout:write("\t" .. text .. "\n")
      elseif Options.show_work then
	 Msg.cont (0, text)
      end
   end
end

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

-- execute shell command and return its standard output (UTIL)
-- the return value is a list with one entry per line without the trailing new-line
local function shell (args)
   local fd1r, fd1w
   local fd2r, fd2w
   if args.jailed and JAILBASE then
      table.insert (args, 1, CHROOT_CMD)
      table.insert (args, 2, JAILBASE)
   end
   if args.as_root and SUDO_CMD then
      table.insert (args, 1, SUDO_CMD)
   end
   local flags = "[" .. table.concat (table.keys (args), ",") .. "]"
   TRACE ("SHELL", flags, table.unpack (args))
   args.to_tty = args.to_tty or args.as_root
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
	 close(fd2r)
	 --local inpfile = io.open ("/dev/tty", "r")
	 local outfile = io.stdout
	 local errfile = io.stderr
	 --dup2 (inpfile, fileno(io.stdin)) -- stdin
	 dup2 (fd1w, fileno(io.stdout)) -- stdout
	 dup2 (fd2w, fileno(io.stderr)) -- stderr
      end
      local cmd, args = args[1], { select (2, table.unpack (args)) }
      local exitcode, errmsg = execp (cmd, args)
      if not args.to_tty then
	 io.stdout = outfile
	 io.stderr = errfile
      end
      assert (exitcode, errmsg)
      _exit (1) -- not reached ???
   else
      if not args.to_tty then
	 close(fd1w)
	 close(fd2w)
	 local poll_cond = {events = {IN = true}}
	 local fds = {[fd1r] = {events = {IN = true}} , [fd2r] = {events = {IN = true}}}
	 local done
	 local result = { [fd1r] = "", [fd2r] = "" }
	 while not done do
	    poll (fds, -1)
	    for fd in pairs (fds) do
	       if fds[fd].revents.IN then
		  result[fd] = result[fd] .. read (fd, 8192)
	       end
	       if fds[fd].revents.HUP then
		  fds[fd] = nil
		  close (fd)
		  if not next (fds) then
		     done = true
		  end
	       end
	    end
	 end
	 local pid, status, exitcode = wait (pid)
	 local result = result[fd1r]
	 TRACE ("==>", result)
	 if result then
	    if args.table then
	       return split_lines (result)
	    else
	       local nl_pos = string.find (result, "\n", 1, true)
	       if nl_pos then
		  if nl_pos < #result then
		     error ("shell command unexpectedly returned multiple lines")
		  end
		  return string.sub (result, 1, nl_pos - 1)
	       end
	    end
	 end
	 return result
      else
	 local pid, status, exitcode = wait (pid)
	 TRACE ("==>", exitcode, status)
	 return exitcode == 0, status
      end
   end
end

-- execute command according to passed flags argument
local function run (args)
   local log_level = args.safe and 2 or 0
   --TRACE ("run", table.concat (table.keys (args), ","), cmd, table.unpack (args))
   log (log_level, table.unpack (args))
   if not Options.dry_run or args.safe then
      if args.table then
	 local result = {}
	 for i, v in ipairs (args) do
	    if string.match (v, "%s") then
	       args[i] = "'" .. v .. "'"
	    end
	 end
	 local cmdline = table.concat (args, " ")
	 --print ("CMD", cmdline)
	 local inp = io.popen (cmdline, "r")
	 if inp then
	    line = inp:read ()
	    while line do
	       table.insert (result, line)
	       line = inp:read ()
	    end
	    io.close (inp)
	    TRACE ("RUN", cmdline, "-->", #result, "lines")
	    return result
	 else
	    return nil, "command failed: cmdline"
	 end
      else
	 return shell (args)
      end
   else
      return "" -- dummy return value for --dry-run
   end
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
   shell = shell,
   shell_pipe = shell_pipe,
}
