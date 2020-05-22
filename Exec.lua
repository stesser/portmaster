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

--[[

Concept for background execution of functions:

- functions that may block waiting for I/O are executed as coroutines
- the I/O is actually performed in the main program (not in a coroutine)
- when I/O is complete (HUP detected) the program waiting for the output is resumed
- when the background job needs to execute an external program it calls yield with
  return values that control the execution (cmd, arguments, flags)
- coroutines for such background functions just return at the end of their code path
  (no return value, results provided by side-effects)
- I/O may be due to execution of an external program or a request for user input
- both reading from a pipe for an external program and STDIN or TTY must be supported
- posix.poll is used to select file descriptors that have data to be read
- the poll timeout should be 0 until some number of tasks has been created
- the poll timeout shall grow with the number of tasks to slow down the main program
  and to limit the number of background tasks it creates
- it might be useful to support tags for background tasks and to be able to wait
  for all tasks with a given tag to have completed
- each task creation should end with a call to polling and reading new data
- there must be a function that waits for all or selected tasks to have terminated
- a use case is the fetching of distribution files
- another use case is adding new actions (which needs to run "make" to obtain values
  for the port and package object instances being created)

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

-------------------------------------------------------------------------------------
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
        pidfd[pid] = {fd}
    else
        table.insert(pidfd[pid], fd)
    end
    pollfds[fd] = {events = {IN = true}}
    result[fd] = {}
    fdpid[fd] = pid
    numpidfds[pid] = (numpidfds[pid] or 0) + 1
end

local function rm_poll_fd(fd)
    local pid = fdpid[fd]
    TRACE("RMPOLL", pid, fd, numpidfds[pid])
    fdpid[fd] = nil
    close(fd)
    pollfds[fd] = nil
    numpidfds[pid] = numpidfds[pid] - 1
    if numpidfds[pid] == 0 then
        return pid
    end
end

-------------------------------------------------------------------------------------
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
        TRACE("EXEC(Child)->", exitcode, errmsg)
        assert (exitcode, errmsg)
        _exit (1) -- not reached ???
    end
    if args.to_tty then
        local _, status, exitcode = wait(pid)
        TRACE("EXEC(Parent)->", exitcode, status)
        return exitcode
    end
    close(fd1w)
    close(fd2w)
    add_poll_fd(pid, fd1r)
    add_poll_fd(pid, fd2r)
    return pid
end

--
local function tasks_poll(timeout)
    local function fetch_result (pid, n)
        local fd = pidfd[pid][n]
        local text = result[fd] and table.concat(result[fd],"")
        result[fd] = nil
        return text
    end
    if next(pollfds) then
        local idle
        timeout = timeout or 0
        while not idle and poll(pollfds, timeout) > 0 do
            idle = true
            for fd in pairs (pollfds) do
                local revents = pollfds[fd].revents
                if revents then
                    if revents.IN then
                        local data = read (fd, 128 * 1024) -- 4096 max on FreeBSD
                        if #data > 0 then
                            table.insert(result[fd], data)
                            idle = false
                        end
                    end
                    if revents.HUP then
                        local pid = rm_poll_fd(fd)
                        if pid then
                            local _, _, exitcode = wait (pid)
                            local stdout = fetch_result(pid, 1)
                            local stderr = fetch_result(pid, 2)
                            local co = tasks[pid]
                            tasks[pid] = nil
                            TRACE ("EXIT", co, exitcode, stdout, stderr)
                            if co then
                                coroutine.resume(co, exitcode, stdout, stderr)
                            else
                                return exitcode, stdout, stderr
                            end
                        end
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------------
-- create coroutine that will allow processes to be executed in the background
local function spawn(f, ...)
    tasks_poll()
    TRACE ("SPAWN", ...)
    local co = coroutine.create(f)
    coroutine.resume(co, ...)
end

--
local function shell(args)
    if args.to_tty then
        return task_create(args)
    end
    local co = coroutine.running()
    local bg = coroutine.isyieldable(co)
    if (bg) then
        -- in coroutine: execute background process
        local pid = task_create(args)
        tasks[pid] = co
        return coroutine.yield()
    else
        -- in main program wait for and return results
        local pid = task_create(args)
        tasks[pid] = false
        local exitcode, stdout, stderr
        while not exitcode do
            exitcode, stdout, stderr = tasks_poll(-1)
        end
        TRACE("SHELL(stdout)", "<" .. (stdout or "") .. ">")
        TRACE("SHELL(stderr)", "<" .. (stderr or "").. ">")
        TRACE("SHELL(exitcode)", exitcode)
        return exitcode, stdout, stderr
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
    local exitcode, stdout, stderr = shell(args)
    if args.to_tty then
        return exitcode == 0
    else
        stdout = chomp(stdout)
        stderr = chomp(stderr)
        if stdout == "" then
            stdout = nil
        end
        if stdout then
            if args.table then
                stdout = split_lines(stdout)
            elseif args.split then
                stdout = split_words(stdout)
            end
        end
        return stdout, stderr, exitcode
    end
end

-- run make command
local function make(args)
    table.insert(args, 1, CMD.make)
    if args.trace then
        table.insert(args, 1, "ktrace") -- CMD.ktrace = /usr/bin/ktrace
        table.insert(args, 2, "-dia")
    end
    return run(args)
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
    return run(args)
end

--
return {make = make, pkg = pkg, run = run, spawn = spawn}
