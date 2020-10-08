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
local LocksTable = {} -- table containing all created lock tables

local tasks_blocked = 0 -- number of coroutines blocked by wait_cond
local BlockedTasks = {} -- table of all currently blocked lock requests

local function tracelockstate(lock)
    TRACE("LocksTable(" .. lock.name .. ")", lock)
end

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
        local L = LocksTable[name]
        if not L then
            L = {name = name, avail = avail, blocked = 0, state = {}}
            setmetatable(L, mt)
            LocksTable[name] = L
            BlockedTasks[L] = {}
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
    local shared = items.shared
    local avail = lock.avail
    local state = lock.state
    local function islocked()
        if avail and avail < (items.weight or 1) then
            TRACE("TRYACQUIRE-", lock.name, avail, items.weight or 1)
            return true
        end
        if shared then
            for _, item in ipairs(items) do
                local listitem = state[item]
                if listitem and listitem.acquired < 0 then
                    TRACE("TRYACQUIRE_SHARED-", lock.name, item, listitem)
                    return true
                end
            end
        else
            for _, item in ipairs(items) do
                local listitem = state[item]
                if listitem and listitem.acquired ~= 0 then
                    TRACE("TRYACQUIRE_EXCLUSIVE-", lock.name, item, listitem)
                    return true
                end
            end
        end
        return false
    end
    local function lockitems_register()
        TRACE("LOCK.ACQUIRE_REGISTER", lock.name, items)
        for _, item in ipairs(items) do
            local listitem = state[item] or {acquired = 0, sharedqueue = {}, exclusivequeue = {}}
            if shared then
                assert(listitem.acquired >= 0)
                listitem.acquired = listitem.acquired + 1
            else
                assert(listitem.acquired == 0)
                listitem.acquired = -1
            end
            state[item] = listitem
        end
        if avail then
            lock.avail = lock.avail - (items.weight or 1)
        end
    end

    if not islocked() then
        lockitems_register()
        return true
    end
    TRACE("LOCK.TRYACQUIRE->", lock.name, items)
end

-- aquire lock with parameters like { item1, item2, ..., shared=true, weight=1 }
local count = 0

local function acquire(lock, items)
    local state = lock.state
    local function lockitems_enqueue(co)
        local shared = items.shared
        for _, item in ipairs(items) do
            TRACE("L", state[item])
            local lockitem = state[item] or {acquired = 0, sharedqueue = {}, exclusivequeue = {}}
            if shared then
                lockitem.sharedqueue[co] = true
            else
                lockitem.exclusivequeue[co] = true
            end
            state[item] = lockitem
            tracelockstate(lock)
        end
        lock.blocked = lock.blocked + 1 -- XXX required ???
    end
    local function locktable_insert(co)
        TRACE("LOCK.ACQUIRE_ENQUEUE", lock.name, items)
        local locktable = BlockedTasks[lock]
        locktable[co] = items
        tasks_blocked = tasks_blocked + 1
        TRACE("BlockedTasks:", BlockedTasks)
    end

    TRACE("LOCK.ACQUIRE", lock.name, items)
    if not tryacquire(lock, items) then
        count = count + 1
        local co = coroutine.running()
        lockitems_enqueue(co)
        locktable_insert(co)
        coroutine.yield()
    end
    TRACE("LOCK.ACQUIRE->", lock.name, items)
    TRACE("BlockedTasks:", BlockedTasks)
    tracelockstate(lock)
    TRACE("---")
end

--
local function release(lock, items)
    local state = lock.state
    local function release_items()
        local shared = items.shared
        local avail = lock.avail
        if avail then
            lock.avail = avail + (items.weight or 1)
        end
        for _, item in ipairs(items) do
            local listitem = state[item]
            --if listitem then
                local acquired = listitem.acquired
                if shared then
                    assert(acquired > 0, lock.name .. ': No shared lock currently acquired for "' .. item .. '"')
                    acquired = acquired - 1
                else
                    assert(acquired == -1, lock.name .. ': No exclusive lock currently acquired for "' .. item .. '"')
                    acquired = 0
                end
                listitem.acquired = acquired
                state[item] = listitem
            --end
        end
    end
    local function released(shared)
        local result = {}
        if lock.avail then
            result = BlockedTasks[lock]
        else
            for _, item in ipairs(items) do
                local listitem = state[item]
                if listitem and listitem.acquired == 0 then
                    local queue = shared and listitem.sharedqueue or listitem.exclusivequeue
                    for co, _ in pairs(queue) do
                        TRACE("LOCK.SET_RELEASED", co)
                        result[co] = true
                    end
                    state[item] = (next(listitem.sharedqueue) or next(listitem.exclusivequeue)) and listitem or nil
                end
            end
        end
        TRACE("LOCK.RELEASE_LIST", result)
        return result
    end
    local function lockitems_dequeue(co, queueitems)
        TRACE("LOCK.WAITDONE", lock.name, co, queueitems)
        for _, item in ipairs(queueitems) do
            local listitem = state[item]
            if queueitems.shared then
                listitem.sharedqueue[co] = nil
            else
                listitem.exclusivequeue[co] = nil
            end
        end
        lock.blocked = lock.blocked - 1
    end
    local function resume_unlocked(resume_list)
        TRACE("BlockedTasks:", BlockedTasks)
        TRACE("RESUME_UNLOCKED", lock.name, resume_list)
        local locktable = BlockedTasks[lock]
        assert(locktable, "No BlockedTasks table named " .. lock.name)
        for co, _ in pairs(resume_list) do
            local queueitems = locktable[co]
            TRACE("LOCK.WAITTEST", lock.name, co, queueitems)
            if queueitems then
                if tryacquire(lock, queueitems) then
                    lockitems_dequeue(co, queueitems)
                    tasks_blocked = tasks_blocked - 1
                    locktable[co] = nil
                    coroutine.resume(co)
                end
            else
                TRACE("LOCK.CLEAR_STALE(2)", lock.name, co, queueitems)
            end
        end
    end

    TRACE("LOCK.RELEASE", lock.name, items)
    release_items()
    resume_unlocked(released(true)) -- shared == true
    resume_unlocked(released(false))-- shared == false
    TRACE("BlockedTasks:", BlockedTasks)
    tracelockstate(lock)
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
    TRACE("LOCK.LocksTable", LocksTable)
    TRACE("LOCK.BlockedTasks", BlockedTasks)
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
