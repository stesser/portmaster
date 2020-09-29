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

--local TRACE = print
local Lock = {} -- Lock module
local LOCKS = {} -- table of all created lock objects

local tasks_blocked = 0 -- number of coroutines blocked by wait_cond
local LockCache = {} -- table of all currently blocked lock requests

local mt = {
    __index = Lock,
    __tostring = function(self)
        return self.name
    end,
}
--!
-- allocate and initialize lock state structure
--
-- @param name name of the lock for identification in trace and debug messages
-- @param avail optional limit on the number of exclusive locks to grant for different items using this lock structure
-- @retval lock the initialized lock structure
local function new(name, avail)
    if name then
        local L = LOCKS[name]
        if not L then
            L = {name = name, avail = avail, blocked = 0}
            setmetatable(L, mt)
            LOCKS[name] = L
            LockCache[name] = {}
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
    local function islocked(lock, items)
        local shared = items.shared
        local avail = lock.avail
        if avail and avail < (items.weight or 1) then
            return true
        end
        for i = 1, #items do
            local item = items[i]
            local listitem = lock[item]
            if listitem then
                if listitem.exclusive or not shared and listitem.sharedcount > 0 then
                    return true
                end
            end
        end
        return false
    end

    local function acquire_register(lock, items)
        TRACE("LOCK.ACQUIRE_REGISTER", lock.name, items)
        local shared = items.shared
        local avail = lock.avail
        if avail then
            lock.avail = avail - (items.weight or 1)
        end
        if shared then
            for i = 1, #items do
                local item = items[i]
                local listitem = lock[item] or {sharedcount = 0}
                listitem.sharedcount = listitem.sharedcount + 1
                lock[item] = listitem
            end
        else
            for _, item in ipairs(items) do
                if lock[item] then
                    lock[item].exclusive = true
                else
                    lock[item] = {exclusive = true}
                end
            end
        end
    end

    local locked = islocked(lock, items)
    if not locked then
        acquire_register(lock, items)
    end
    TRACE("LOCK.TRYACQUIRE->", not locked, lock.name, items)
    --    TRACE("LockCache:", LockCache)
    --    TRACE("LockList:", lock)
    return not locked
end


-- aquire lock with parameters like { item1, item2, ..., shared=true, weight=1 }
local count = 0

local function acquire(lock, items)
    local function acquire_enqueue(lock, items)
        TRACE("LOCK.ACQUIRE_ENQUEUE", lock.name, items)
        count = count + 1
        local key = items.tag or "<" .. count .. ">" items.tag = nil -- XXX tag or anonymous table {}
        local co = coroutine.running()
        local lockcache = LockCache[lock.name]
        lockcache[key] = {lock = lock, co = co, items = items}
        for i = 1, #items do
            local item = items[i]
            if lock[item] then
                table.insert(lock[item], key)
            else
                lock[item] = {sharedcount = 0, key}
            end
        end
        tasks_blocked = tasks_blocked + 1
        lock.blocked = lock.blocked + 1
        TRACE("LockCache:", LockCache)
        TRACE("LockList:", lock)
        coroutine.yield()
    end

    TRACE("LOCK.ACQUIRE", lock.name, items)
    if not tryacquire(lock, items) then
        acquire_enqueue(lock, items)
    end
    TRACE("LOCK.ACQUIRE->", lock.name, items)
    TRACE("LockCache:", LockCache)
    TRACE("LockList:", lock)
    TRACE("---")
end

local function release_items(lock, items)
    local shared = items.shared
    local released = {}
    local function set_released(listitem)
        for _, key in ipairs(listitem or {}) do
            TRACE("LOCK.SET_RELEASED", key)
            released[key] = true
        end
    end
    local avail = lock.avail
    if avail then
        lock.avail = avail + (items.weight or 1)
    end
    for i = #items, 1, -1 do
        local item = items[i]
        local listitem = lock[item] or { exclusive = false, sharedcount = 0 }
        local sharedcount = listitem.sharedcount or 0
        local exclusive = listitem.exclusive
        assert(not (exclusive and sharedcount ~= 0),
            "Illegal combination of sharedcount==" .. sharedcount ..
            " and exclusive==" .. tostring(exclusive) ..
            " for \"" .. item .. "\"")
        if shared then
            assert(sharedcount > 0, "No shared lock currently acquired for \"" .. item .. "\"")
            sharedcount = sharedcount - 1
            if sharedcount == 0 then
                set_released(listitem)
            end
        else
            assert(exclusive, "No exclusive lock currently acquired for \"" .. item .. "\"")
            exclusive = nil
            set_released(listitem)
        end
        if sharedcount == 0 and not exclusive then
            lock[item] = nil
        else
            lock[item].sharedcount = sharedcount
            lock[item].exclusive = exclusive
        end
    end
    TRACE("LOCK.RELEASE_LIST", released)
    return released
end

--
local function release(lock, items)
    local function resume_unlocked(lock, released)
        --for key, _ in pairs(released) do
        --    local lockstate = LockCache[lock.name][key]
        TRACE("LockCache:", LockCache)
        --local keys = table.keys(LockCache)
        local lockcache = LockCache[lock.name]
        assert(lockcache, "No LockCache table named " .. lock.name)
        for key, lockstate in pairs(lockcache) do -- XXX ipairs() may fail due to deletion of active element in other coroutine
            if lockstate and lockstate.lock == lock then
                local tryitems = lockstate.items
                local locked = tryacquire(lock, tryitems)
                if locked then
                    local co = lockstate.co
                    lockcache[key] = nil
                    if co then
                        lock.blocked = lock.blocked - 1
                        tasks_blocked = tasks_blocked - 1
                        coroutine.resume(co)
                        break
                    end
                end
            end
        end
    end

    TRACE("LOCK.RELEASE", lock.name, items)
    local released = release_items(lock, items)
    --TRACE("LOCK.RELEASED", lock.name, released)
    resume_unlocked(lock, released)
    TRACE("LockCache:", LockCache)
    TRACE("LockList:", lock)
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
    for k, v in pairs(LOCKS) do
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
