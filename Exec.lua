--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019, 2020 Stefan Eßer <se@freebsd.org>

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

-------------------------------------------------------------------------------------
local Options = require("Options")
local Msg = require("Msg")

-------------------------------------------------------------------------------------
local P = require("posix")
local _exit = P._exit
local poll = P.poll
local read = P.read

local P_IO = require("posix.stdio")
local fdopen = P_IO.fdopen
local fileno = P_IO.fileno

local P_SL = require("posix.stdlib")
local setenv = P_SL.setenv

local P_SW = require("posix.sys.wait")
local wait = P_SW.wait

local P_US = require("posix.unistd")
local close = P_US.close
local dup2 = P_US.dup2
local execp = P_US.execp
local fork = P_US.fork
local pipe = P_US.pipe

-------------------
-- indexed by fd:
local pollfds = {} -- file descriptors for poll
local result = {} -- table of tables with output received from file descriptor
local fdpid = {} -- table mapping file descriptors to pids
-- indexed by pid:
local numpidfds = {} -- number of open file descriptors for given pid
local pidfd = {} -- file descriptors (stdout, stderr) for this pid
local tasks = {} -- task table with arguments for finalization of background jobs per pid

local function add_poll_fd(pid, fd)
    TRACE("ADDPOLL", pid, fd)
    if not pidfd[pid] then
        pidfd[pid] = {}
    end
    table.insert(pidfd[pid], fd)
    pollfds[fd] = {events = {IN = true}}
    result[fd] = {}
    fdpid[fd] = pid
    numpidfds[pid] = (numpidfds[pid] or 0) + 1
end

local function rm_poll_fd(fd)
    local pid = fdpid[fd]
    TRACE("RMPOLL", pid, fd)
    fdpid[fd] = nil
    close(fd)
    pollfds[fd] = nil
    numpidfds[pid] = numpidfds[pid] - 1
    if numpidfds[pid] == 0 then
        return pid
    end
end

------------
local function task_create (args)
    --TRACE("TASK_CREATE", table.unpack(args))
    local fd1r, fd1w
    local fd2r, fd2w
    if not args.to_tty then
        fd1r, fd1w = pipe()
        fd2r, fd2w = pipe()
    end
    local pid, errmsg = fork()
    assert(pid, errmsg)
    if pid == 0 then
        -- child process
        if not args.to_tty then
            close(fd1r)
            dup2(fd1w, fileno(io.stdout)) -- stdout
            close(fd2r)
            dup2(fd2w, fileno(io.stderr)) -- stderr
        end
        if args.env then
            for k, v in pairs(args.env) do
                setenv(k, v)
            end
        end
        local cmd = table.remove(args, 1)
        local exitcode, errmsg = execp (cmd, args)
        TRACE("EXECP", exitcode, errmsg)
        assert (exitcode, errmsg)
        _exit (1) -- not reached ???
    end
    if args.to_tty then
        local pid, status, exitcode = wait(pid)
        TRACE("==>", exitcode, status)
        return exitcode == 0
    end
    close(fd1w)
    close(fd2w)
    add_poll_fd(pid, fd1r)
    add_poll_fd(pid, fd2r)
    if args.finalize then
        TRACE ("ADDTASK", pid, args)
        tasks[pid] = args
    end
    return pid
end

--
local function poll_fds(timeout)
  timeout = timeout or -1
  local idle
  while not idle do
    idle = true
    if poll(pollfds, timeout) == 0 then
      return
    end
    for fd in pairs (pollfds) do
      if pollfds[fd].revents.IN then
        local data = read (fd, 128 * 1024) -- 4096 max on FreeBSD
        if #data > 0 then
          table.insert(result[fd], data)
          idle = false
        else
          if pollfds[fd].revents.HUP then
            local pid = rm_poll_fd(fd)
            if pid then
              return pid
            end
          end
        end
      end
    end
  end
end

--
local function shell_run (timeout)
  local function fetch_result (pid, n)
    local fd = pidfd[pid][n]
    local text = table.concat(result[fd],"")
    result[fd] = nil
    return text
  end
  while next(pollfds) do
    local pid = poll_fds (timeout)
    if pid then
      local _, _, exitcode = wait (pid)
      return pid, exitcode, fetch_result(pid, 1), fetch_result(pid, 2)
    end
  end
end

--
local function tasks_poll(waitpid)
    TRACE("TASKSPOLL", waitpid, next(tasks))
    local timeout = waitpid and -1 or 0
    while next(tasks) or waitpid do
        local pid, exitcode, stdout, stderr = shell_run(timeout)
        if pid then
            TRACE("WAIT->", pid, exitcode)
            if waitpid == pid then
                tasks[pid] = nil
                TRACE("TASKSPOLL->", stdout)
                return exitcode, stdout, stderr
            end
            local args = tasks[pid]
            local f = args.finalize
            f(args.finalize_arg, stdout, stderr, exitcode)
            tasks[pid] = nil
        end
        if not waitpid then
            return
        end
    end
end

-- execute shell command and return its standard output (UTIL) -- not exported !!!
-- the return value is a list with one entry per line without the trailing new-line
local function shell(args)
    local pid = task_create(args)
    if not args.to_tty then
        local exitcode, stdout, stderr = tasks_poll(pid)
        TRACE("==>", exitcode)
        if (args.table) then
            return split_lines(stdout)
        else
            return stdout
        end
    end
end

-- execute command according to passed flags argument
local function run(args)
    TRACE("run", "[" .. table.concat(table.keys(args), ",") .. "]", table.unpack(args))
    if PARAM.jailbase and args.jailed then
        table.insert(args, 1, CMD.chroot)
        table.insert(args, 2, PARAM.jailbase)
        if not args.as_root and CMD.sudo then -- chroot needs root but can then switch back to user
            args.as_root = true
            table.insert(args, 2, "-u")
            table.insert(args, 3, PARAM.user)
        end
    end
    if args.as_root and CMD.sudo then
        table.insert(args, 1, CMD.sudo)
        if args.env then -- does not work with doas as CMD.sudo !!!
            for k, v in pairs(args.env) do
                table.insert(args, 2, k .. "=" .. v)
            end
            args.env = nil
        end
    end
    if args.log then
        if Options.dry_run or Options.show_work then
            local args = args
            for i, v in ipairs(args) do
                if string.match(v, "%s") then
                    args[i] = "'" .. v .. "'"
                end
            end
            args.level = args.safe and 2 or 0
            if Options.dry_run then
                Msg.show {verbatim = true, "\t" .. table.concat(args, " ") .. "\n"}
            else
                Msg.show(args)
            end
        end
    end
    if Options.dry_run and not args.safe then
        return args.table and {} or "" -- dummy return value for --dry-run
    end
    return shell(args)
end

-- run make command
local function make(args)
    table.insert(args, 1, CMD.make)
    if args.trace then
        table.insert(args, 1, "ktrace")
        table.insert(args, 2, "-dia")
    end
    -- local result = shell (args)
    local result = run(args)
    if result then
        if args.split then
            result = split_words(result)
        end
        if result == "" then
            result = nil
        end
    end
    return result
end

-- execute and log a package command that does not modify any state (JAILED)
local function pkg(args)
    if args.jailed then
        if PARAM.jailbase then
            table.insert(args, 1, "-c")
            table.insert(args, 2, PARAM.jailbase)
        end
        args.jailed = nil
    end
    if Options.developer_mode then
        table.insert(args, 1, "--debug")
    end
    table.insert(args, 1, CMD.pkg)
    -- return shell (args)
    return run(args)
end

--
return {make = make, pkg = pkg, run = run}
