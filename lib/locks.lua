--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019, 2020 Stefan Eßer <se@freebsd.org>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following itemitions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of itemitions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of itemitions and the following disclaimer in the
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
-------------------------------------------------------------------------------

local Lock = {} -- Lock module
local LockState = {} -- table of all created lock objects

local tasks_blocked = 0 -- number of coroutines blocked by wait_cond
local LockQueue = {} -- table of all currently blocked lock requests

local mt = {
    __index = Lock,
    __tostring = function(self)
        return self.name
    end
}
--!
-- allocate and initialize lock state structure
--
-- @param name name of the lock for identification in trace and debug messages
-- @param avail optional limit on the number of exclusive locks to grant for different items using this lock structure
-- @retval lock the initialized lock structure
local function new(name, avail)
    if name then
        local L = LockState[name]
        if not L then
            L = {name = name, avail = avail, blocked = 0}
            setmetatable(L, mt)
            LockState[name] = L
            LockQueue[L] = {}
            TRACE("Lock.NEW", name)
        else
            TRACE("Lock.NEW", name, "(cached)")
        end
        return L
    end
end

--!
-- general resource locking function
--
-- @param lock state structure allocated with new()
-- @param items table of items to be locked
-- @param items.shared true if a shared lock is requested
-- @param items.weight weight factor for this lock
-- @retval false the lock could not be acquired without waiting
-- @retval true the locks requested in the items table have been acquired
-- @todo recursive locking or upgrading from a shared to a exclusive lock is not supported (yet?)
local function tryacquire(lock, items)
    local function islocked()
        local avail = lock.avail
        if avail and avail < (items.weight or 1) then
            return true
        end
        for _, item in ipairs(items) do
            local listitem = lock[item]
            if listitem and listitem.acquired ~= 0 then
                return true
            end
        end
        return false
    end

    local function acquire_register()
        TRACE("LOCK.ACQUIRE_REGISTER", lock.name, items)
        local shared = items.shared
        local avail = lock.avail
        if avail then
            lock.avail = avail - (items.weight or 1)
        end
        for _, item in ipairs(items) do
            local listitem = lock[item] or {acquired = 0, sharedqueue = {}, exclusivequeue = {}}
            if shared then
                assert(listitem.acquired >= 0)
                listitem.acquired = listitem.acquired + 1
            else
                assert(listitem.acquired == 0)
                listitem.acquired = -1
            end
            lock[item] = listitem
        end
    end

    if not islocked() then
        acquire_register()
        return true
    end
    TRACE("LOCK.TRYACQUIRE->", lock.name, items)
end

-- aquire lock with parameters like { item1, item2, ..., shared=true, weight=1 }
local count = 0

local function acquire(lock, items)
    local function acquire_enqueue(lock, items)
        TRACE("LOCK.ACQUIRE_ENQUEUE", lock.name, items)
        count = count + 1
        local key = items.tag or "<" .. count .. ">" -- XXX tag or anonymous table {}
        items.tag = nil
        local co = coroutine.running()
        local lockwaitrecord = LockQueue[lock]
        lockwaitrecord[key] = {co = co, items = items}
        local shared = items.shared
        for _, item in ipairs(items) do
            TRACE("L", lock[item])
            local lockitem = lock[item] or {acquired = 0, sharedqueue = {}, exclusivequeue = {}}
            if shared then
                lockitem.sharedqueue[key] = true
            else
                lockitem.exclusivequeue[key] = true
            end
            lock[item] = lockitem
        end
        tasks_blocked = tasks_blocked + 1
        lock.blocked = lock.blocked + 1 -- XXX required ???
        TRACE("LockQueue:", LockQueue)
        TRACE("LockState:", lock)
        coroutine.yield()
    end

    TRACE("LOCK.ACQUIRE", lock.name, items)
    if not tryacquire(lock, items) then
        acquire_enqueue(lock, items)
    end
    TRACE("LOCK.ACQUIRE->", lock.name, items)
    TRACE("LockQueue:", LockQueue)
    TRACE("LockState:", lock)
    TRACE("---")
end

--
local function release(lock, items)
    local function release_items()
        local shared = items.shared
        local avail = lock.avail
        if avail then
            lock.avail = avail + (items.weight or 1)
        end
        for _, item in ipairs(items) do
            local listitem = lock[item] -- or {acquired = 0, sharedqueue = {}, exclusivequeue = {}, I=3}
            if listitem then
                local acquired = listitem.acquired
                if shared then
                    assert(acquired > 0, lock.name .. ': No shared lock currently acquired for "' .. item .. '"')
                    acquired = acquired - 1
                else
                    assert(acquired == -1, lock.name .. ': No exclusive lock currently acquired for "' .. item .. '"')
                    acquired = 0
                end
                listitem.acquired = acquired
                lock[item] = listitem
            end
        end
    end
    local function released(shared)
        local result = {}
        local lockwaitrecord = LockQueue[lock]
        for i = #items, 1, -1 do -- XXX reverse of allocation order to prevent deadlocks (required???)
            local item = items[i]
            local listitem = lock[item] or {acquired = 0, sharedqueue = {}, exclusivequeue = {}, I=3}
            if listitem.acquired == 0 then
                local queue = shared and listitem.sharedqueue or listitem.exclusivequeue
                for key, _ in pairs(queue) do
                    if lockwaitrecord[key] then
                        TRACE("LOCK.SET_RELEASED", key)
                        result[key] = true
                    else
                        TRACE("LOCK.CLEAR_STALE(1)", lock.name, key, item)
                        listitem.sharedqueue[key] = nil
                        listitem.exclusivequeue[key] = nil
                    end
                end
            end
            lock[item] = (next(listitem.sharedqueue) or next(listitem.exclusivequeue)) and listitem or nil
        end
        TRACE("LOCK.RELEASE_LIST", result)
        return result
    end
    local function resume_unlocked(resume_list)
        TRACE("LockQueue:", LockQueue)
        local lockwaitrecord = LockQueue[lock]
        assert(lockwaitrecord, "No LockQueue table named " .. lock.name)
        for key, _ in pairs(resume_list) do
            local lockstate = lockwaitrecord[key]
            TRACE("LOCK.WAITTEST", lock.name, key, lockstate and (lockstate.lock == lock), lockstate)
            if lockstate then
                if tryacquire(lock, lockstate.items) then
                    TRACE("LOCK.WAITDONE", lockstate.items)
                    for _, item in ipairs(lockstate.items) do
                        local listitem = lock[item]
                        if listitem then
                            listitem.sharedqueue[key] = nil
                            listitem.exclusivequeue[key] = nil
                        end
                    end
                    local co = lockstate.co
                    lock.blocked = lock.blocked - 1
                    tasks_blocked = tasks_blocked - 1
                    lockwaitrecord[key] = nil
                    coroutine.resume(co)
                end
            else
                TRACE("LOCK.CLEAR_STALE(2)", lock.name, key, items)
            end
        end
    end

    TRACE("LOCK.RELEASE", lock.name, items)
    release_items()
    resume_unlocked(released(true))
    resume_unlocked(released(false))
    TRACE("LockQueue:", LockQueue)
    TRACE("LockState:", lock)
    TRACE("---")
end

--
local function blocked_tasks(lock)
    if lock then
        return lock.blocked
    else
        return tasks_blocked
    end
end

--
local function trace_locked()
    for k, v in pairs(LockState) do
        TRACE("LOCK.TRACE_LOCKED", k, v)
    end
end

--
local function destroy(lock)
    if (lock.blocked > 0) then
        trace_locked()
    end
    assert(lock.blocked == 0)
end

--[[
local TestLock = new ("TestLock", 2)

local function T (delay, items)
    print ("-----------------", items.tag)
    print ("--(1)-- " .. delay)
    acquire(TestLock, items)
    print ("--(2)-- " .. delay)
    --Exec.run{"/bin/sh", "-c", "sleep " .. delay .. "; echo DONE " .. delay}
    Exec.run{"/bin/sleep" , delay}
    print ("--(3)-- " .. delay)
    release(TestLock, items)
    print ("--(4)-- " .. delay)
end

Exec.spawn(T, 4, {shared = false, tag="A", "a", "b"})
--[=[
Exec.spawn(T, 3, {shared = true,  tag="B", "a", "c"})
Exec.spawn(T, 2, {shared = true,  tag="C", "a", "c"})
Exec.spawn(T, 1, {shared = true,  tag="D", "a", "c"})
Exec.spawn(T, 1, {shared = false, tag="E", "a", "b"})
--]=]

Exec.finish_spawned()

destroy(TestLock)

--]]
-- module interface
Lock.new = new
Lock.destroy = destroy
Lock.acquire = acquire
Lock.release = release
Lock.tryacquire = tryacquire
Lock.blocked_tasks = blocked_tasks
Lock.trace_locked = trace_locked

return Lock

--[[

further required locking primitives:

references:
    -- e.g. to prevent premature deletion of some actively used resource
    reference_acqire
    reference_release
    reference_wait_done
    --> could also be implemented as "read lock" (shared lock)

semaphores:
    -- can be initialized to
    -- 0: blocking until first released
    -- n > 0: can be acquired n times before next attempt leads to blocking
    -- n < 0: must be released n times before it can be successfully acquired (useful???)
    semaphore_acquire
    semaphore_release

--]]
