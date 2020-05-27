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
--local fdopen = P_IO.fdopen
local fileno = P_IO.fileno

local P_SL = require("posix.stdlib")
local setenv = P_SL.setenv

local P_SW = require("posix.sys.wait")
local wait = P_SW.wait

local P_US = require("posix.unistd")
local close = P_US.close
local dup2 = P_US.dup2
local exec = P_US.exec
local fork = P_US.fork
local pipe = P_US.pipe
--local sleep = P_US.sleep

-------------------------------------------------------------------------------------
-- indexed by fd:
local pollfds = {} -- file descriptors for poll
local fdstat = {} -- result, pid
--local result = {} -- table of tables with output received from file descriptor
--local fdpid = {} -- table mapping file descriptors to pids
-- indexed by pid:
local pidstat = {} -- fds, numfds
--local numpidfds = {} -- number of open file descriptors for given pid
--local pidfd = {} -- file descriptors (stdout, stderr) for this pid

local function add_poll_fds(pid, fds)
    TRACE("ADDPOLL", pid, fds[1], fds[2])
    pidstat[pid] = {fds = fds, numfds = 2}
    local fd1, fd2 = fds[1], fds[2]
    fdstat[fd1] = {pid = pid, result = {}}
    fdstat[fd2] = {pid = pid, result = {}}
    pollfds[fd1] = {events = {IN = true}}
    pollfds[fd2] = {events = {IN = true}}
end

local function rm_poll_fd(fd)
    TRACE("RM", fd)
    local pid = fdstat[fd].pid
    TRACE("RMPOLL", pid, fd, pidstat[pid].numfds)
    pollfds[fd] = nil
    local numfds = pidstat[pid].numfds - 1
    if numfds > 0 then
        if fd == pidstat[pid].fds[1] then
            TRACE("RMPOLLFD", pid, fd, "STDOUT")
        elseif fd == pidstat[pid].fds[2] then
            TRACE("RMPOLLFD", pid, fd, "STDERR")
        else
            TRACE("RMPOLLFD", pid, fd, "???")
        end
        pidstat[pid].numfds = numfds
    else
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
        local exitcode, errmsg = exec (cmd, args)
        TRACE("FAILED-EXEC(Child)->", exitcode, errmsg)
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
    add_poll_fds(pid, {fd1r, fd2r})
    return pid
end

--
local max_tasks -- initialised when count of CPUs/HW-threads is known
local co_table = {} -- mapping from pid to coroutine
local tasks_spawned = 0 -- number of currently existing coroutines
local tasks_spawned_with = {} -- mapping of function used to start coroutine to count of active coroutines
local tasks_forked = 0 -- number of forked processes
local tasks_blocked = 0 -- number of coroutines blocked by wait_cond
local task_wait_func = {} -- table of check functions for blocked tasks

local function tasks_poll(timeout)
    local function fetch_result (pid, n)
        local fd = pidstat[pid].fds[n]
        local fdrec = fdstat[fd]
        fdstat[fd] = nil
        local t = fdrec.result
        close(fd) -- do not move, must stay behind copying of result
        local count = t and #t or 0
        local text
        if count > 0 then
            t[count] = chomp(t[count])
            text = table.concat(t, "")
        end
        --TRACE("FETCH_RESULT", pid, fd, n, text and #text or 0)
        return text
    end
    local function pollms()
        max_tasks = max_tasks or PARAM.ncpu and (PARAM.ncpu + 4)
        local n = tasks_forked - (max_tasks or 4)
        return n <= 0 and 0 or (10 * n)
    end
    --local numreads = 0
    --assert(tasks_spawned - tasks_forked - tasks_blocked <= 2, "TASKS: " .. tasks_spawned .. "/" .. tasks_forked .. "/" .. tasks_blocked)
    if timeout or next(pollfds) then
        local idle
        timeout = timeout or pollms()
        TRACE("POLL", timeout)
        while not idle and poll(pollfds, timeout) > 0 do -- XXX add test for "terminated" variable set by fail et. al.
            idle = true
            for fd in pairs(pollfds) do
                local revents = pollfds[fd].revents
                if revents then
                    if revents.IN then
                        local data = read (fd, 128 * 1024) -- 4096 max on FreeBSD
                        if #data > 0 then
                            table.insert(fdstat[fd].result, data)
                            TRACE("READ", fdstat[fd].pid, fd, #data)
                            idle = false
                            --numreads = numreads + 1
                        elseif revents.HUP then
                            local pid = rm_poll_fd(fd)
                            if pid then
                                local _, _, exitcode = wait (pid)
                                local stdout = fetch_result(pid, 1)
                                local stderr = fetch_result(pid, 2)
                                pidstat[pid] = nil
                                local co = co_table[pid]
                                assert(task_wait_func[co] == nil, "attempt to resume blocked coroutine")
                                co_table[pid] = nil
                                --TRACE("NUMREADS", numreads)
                                if co then
                                    TRACE ("EXIT(resume)", co, exitcode, stdout, stderr)
                                    coroutine.resume(co, exitcode, stdout, stderr)
                                else
                                    TRACE ("EXIT(return)", co, exitcode, stdout, stderr)
                                    return exitcode, stdout, stderr
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if tasks_blocked > 0 then
        for co, t in pairs(task_wait_func) do
            local cond = t.f (table.unpack (t.args))
            TRACE("WAIT_CHECK", cond, table.unpack(t.args))
            if cond then
                TRACE("WAIT_DONE", table.unpack(t.args))
                task_wait_func[co] = nil
                coroutine.resume(co)
            end
        end
    end
    --TRACE("NUMREADS", numreads)
end

-------------------------------------------------------------------------------------
local function finish_spawned (f, msg) -- if f is provided then only spawns of that function will be waited for XXX
    while true do
        local n = f and tasks_spawned_with[f] or tasks_spawned -- (tasks_forked + tasks_blocked)
        if n == 0 then
            break
        end
        if msg then
            Msg.show{start = true, level = 2, msg}
            msg = nil
        end
        TRACE("FINISH", tasks_spawned, tasks_forked, tasks_blocked, n, f)
        tasks_poll(tasks_blocked > 0 and 100 or -1)
    end
end

-- create coroutine that will allow processes to be executed in the background
local function spawn(f, ...)
    local function wrapper(f, ...)
        tasks_spawned = tasks_spawned + 1
        tasks_spawned_with[f] = (tasks_spawned_with[f] or 0) + 1
        xpcall (f, debug.traceback, ...)
        tasks_spawned = tasks_spawned - 1
        tasks_spawned_with[f] = tasks_spawned_with[f] - 1
    end
    tasks_poll()
    TRACE ("SPAWN", f, ...)
    local co = coroutine.create(wrapper)
    coroutine.resume(co, f, ...)
end

--
local function cond_wait(f, ...)
    TRACE("COND_WAIT", ...)
    local co = coroutine.running()
    assert (coroutine.isyieldable(co), "cond_wait called ouside of spawned function")
    task_wait_func[co] = {f = f, args = {...}}
    tasks_blocked = tasks_blocked + 1
    TRACE("NUM_TASKS<", tasks_spawned, tasks_forked, tasks_blocked)
    coroutine.yield()
    tasks_blocked = tasks_blocked - 1
    TRACE("NUM_TASKS>", tasks_spawned, tasks_forked, tasks_blocked)
end

--
local function shell(args)
    if args.to_tty then
        return task_create(args)
    end
    local co = coroutine.running()
    local bg = coroutine.isyieldable(co)
    local pid = task_create(args)
    if (bg) then
        -- in coroutine: execute background process
        co_table[pid] = co
        return coroutine.yield()
    else
        -- in main program wait for and return results
        co_table[pid] = false
        local exitcode, stdout, stderr
        while not exitcode do
            TRACE("WAIT FOR DATA - PID=", pid)
            exitcode, stdout, stderr = tasks_poll(-1)
        end
        TRACE("SHELL(stdout)", "<" .. (stdout or "") .. ">")
        TRACE("SHELL(stderr)", "<" .. (stderr or "").. ">")
        TRACE("SHELL(exitcode)", exitcode)
        co_table[pid] = nil
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
            table.insert(args, 2, "-p" .. "#   >>>\tEnter password of user %p: ")
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
            if Options.dry_run then
                Msg.show {verbatim = true, "\t" .. table.concat(args, " ") .. "\n"}
            else
                args.level = args.safe and 2 or 0
                Msg.show(args)
            end
        end
    end
    if Options.dry_run and not args.safe then
         -- dummy return values for --dry-run
        if args.table then
            return {}, "", 0
        else
            return "", "", 0
        end
    end
    tasks_forked = tasks_forked + 1
    TRACE("NUM_TASKS+", tasks_spawned, tasks_forked, tasks_blocked)
    local exitcode, stdout, stderr = shell(args)
    tasks_forked = tasks_forked - 1
    TRACE("NUM_TASKS-", tasks_spawned, tasks_forked, tasks_blocked)
    if args.to_tty then
        return exitcode == 0
    else
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
        table.insert(args, 1, CMD.ktrace)
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
return {
    make = make,
    pkg = pkg,
    run = run,
    spawn = spawn,
    cond_wait = cond_wait,
    finish_spawned = finish_spawned,
}
