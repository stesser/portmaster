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

-------------------------------------------------------------------------------------
--

--local TRACE = print

local tasks_blocked = 0 -- number of coroutines blocked by wait_cond -- CURRENTLY UNUSED -> move to Locks module
local blocked = {} --! table for all currently blocked coroutines waiting for a lock to be acquired

--!
-- allocate and initialize lock state structure
--
-- @param name name of the lock for identification in trace and debug messages
-- @param avail optional limit on the number of exclusive locks to grant for different items using this lock structure
-- @retval lock the initialized lock structure
local function new(name, avail)
    return {name = name, avail = avail, blocked = 0, is_shared = {}, shared = {}, exclusive = {}, shared_queue = {}, exclusive_queue = {}}
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
    TRACE("TRYACQUIRE", lock.name, items.shared, items.weight, items)
    --assert(type(items) == "table", "tryacquire expects table as the 2nd argument but got " .. type(items))
    --assert(lock and lock.name, "Attempt to acquire lock using an unitialized lock structure for " .. tostring(item))
    local shared = items.shared or false
    --local co = items.co or coroutine.running()
    if shared then
        for i = 1, #items do
            if lock.exclusive[items[i]] then
                TRACE("TRYACQUIRE-", lock.name, "item=", items[i])
                return false
            end
        end
        for i = 1, #items do
            local item = items[i]
            local n = lock.shared[item] or 0
            TRACE("TRYACQUIRE(shared)+", lock.name, shared, n+1, item)
            lock.shared[item] = n + 1
            lock.is_shared[item] = shared
        end
    else
        local weight = items.weight or 1
        local avail = lock.avail
        if avail then
            avail = avail - (weight or 1) * #items
            if avail < 0 then
                TRACE("TRYACQUIRE-", lock.name, "avail=", avail)
                return false, avail
            end
        end
        for i = 1, #items do
            local item = items[i]
            if lock.exclusive[item] or lock.shared[item] then
                TRACE("TRYACQUIRE-", lock.name, "item=", item)
                return false, avail, item
            end
        end
        lock.avail = avail --  may be nil
        for i = 1, #items do
            local item = items[i]
            lock.exclusive[item] = weight
            lock.is_shared[item] = shared
            TRACE("TRYACQUIRE+", lock.name, shared, weight, lock.exclusive[item], item)
        end
    end
    return true
end

--
local function acquire(lock, items)
    if not tryacquire(lock, items) then
        local co, in_main = coroutine.running()
        assert(not in_main, "Attempt to acquire lock outside of coroutine")
        TRACE("ACQUIRE_WAIT", co, lock.name, items.shared or false, items.weight or 1, table.unpack(items))
        blocked[items] = co
        TRACE("ACQUIRE_BLOCKED", co, items)
        for i = 1, #items do
            local item = items[i]
            if items.shared then
                local t = lock.shared_queue[item] or {}
                table.insert(t, items)
                lock.shared_queue[item] = t
            else
                local t = lock.exclusive_queue[item] or {}
                table.insert(t, items)
                lock.exclusive_queue[item] = t
            end
        end
        tasks_blocked = tasks_blocked + 1
        lock.blocked = lock.blocked + 1
        coroutine.yield()
        --return coroutine.yield()
    end
    TRACE("ACQUIRE->", lock.name, table.unpack(items))
end

--
local function release_one(lock, item)
    --local co = coroutine.running()
    local shared = lock.shared[item]
    TRACE("RELEASE_ONE", lock.name, shared, item)
    if shared then
        assert(shared > 0, "Attempt to release unlocked shared item" .. tostring(item))
        lock.shared[item] = shared > 1 and (shared - 1) or nil
    else
        local weight = lock.exclusive[item]
        assert(weight, "Attempt to release unlocked exclusive item" .. tostring(item))
        if lock.avail then
            lock.avail = lock.avail + weight
        end
        lock.exclusive[item] = nil
    end
end

local function release (lock, items)
    TRACE("RELEASE", lock.name, lock.blocked, #items, table.unpack(items))
    if #items < 1 then
        TRACE("RELEASE: #items<1")
        return
    end
    assert(type(items) == "table", "release() expects table of items but got " .. type (items))
    assert(lock and lock.name, "Attempt to release lock using an unitialized lock structure for " .. tostring(items[1]))
    for i = #items, 1, -1 do
        release_one(lock, items[i])
    end
    if lock.blocked > 0 then
        TRACE("RELEASE blocked=", lock.blocked, tasks_blocked)
        for i = #items, 1, -1 do
            local item = items[i]
            -- prefer queued shared lock requests over exclusive ones and look for them first
            local queue = lock.shared_queue[item]
            TRACE("RELEASE_SHARED_QUEUE", item, queue)
            if queue then
                for j, items in pairs(queue) do
                    local co = blocked[items]
                    if co then
                        items.co = co
                        if tryacquire(lock, items) then
                            tasks_blocked = tasks_blocked - 1
                            lock.blocked = lock.blocked - 1
                            blocked[items] = nil
                            queue[j] = nil -- use loop with pairs(shared-queue) instead ???
                            TRACE("RELEASE_RESUME_SHARED", lock.name, co, table.unpack(items))
                            coroutine.resume(co)
                        end
                    else
                        queue[j] = nil -- use loop with pairs(shared-queue) instead ???
                    end
                end
                if not next(queue) then
                    lock.shared_queue[item] = nil
                end
            end
            -- retest, if no shared lock at this time then look for blocked exclusive lock requests
            queue = lock.shared_queue[item]
            if not queue then
                local exclusive_queue = lock.exclusive_queue[item]
                TRACE("RELEASE_EXCLUSIVE_QUEUE", item, exclusive_queue)
                if exclusive_queue then
                    for j, items in pairs(exclusive_queue) do -- , 1, -1 do -- always release in reverse order to prevent dead-locks!
                        local co = blocked[items]
                        if co then
                            items.co = co
                            if tryacquire(lock, items) then
                                tasks_blocked = tasks_blocked - 1
                                lock.blocked = lock.blocked - 1
                                blocked[items] = nil
                                exclusive_queue[j] = nil
                                TRACE("RELEASE_RESUME_EXCLUSIVE", lock.name, co, table.unpack(items))
                                coroutine.resume(co)
                            end
                        else
                            exclusive_queue[j] = nil
                        end
                    end
                    if not next(exclusive_queue) then
                        lock.exclusive_queue[item] = nil
                    end
                end
            end
        end
    end
    TRACE("RELEASE_DONE", lock.name, lock.blocked)
end

local function blocked_tasks()
   return tasks_blocked
end

--[[
function table.keys(t)
    local result = {}
    for k, _ in pairs(t) do
        result[#result + 1] = k
    end
    return result
end
--]]

local function destroy (lock)
    assert(lock and lock.name and lock.blocked == 0)
    TRACE("DESTROY", lock.name, lock.blocked)
    if next(lock.shared) then
        TRACE("DESTROY_SHARED!", lock.name, table.unpack(table.keys(lock.shared)))
        lock.shared = nil
    end
    if next(lock.shared_queue) then
        TRACE("DESTROY_SHARED_QUEUE!", lock.name, table.unpack(table.keys(lock.shared_queue)))
        lock.shared_queue = nil
    end
    if next(lock.exclusive) then
        TRACE("DESTROY_EXCLUSIVE!", lock.name, table.unpack(table.keys(lock.exclusive)))
        lock.exclusive = nil
    end
    if next(lock.exclusive_queue) then
        TRACE("DESTROY_EXCLUSIVE_QUEUE!", lock.name, table.unpack(table.keys(lock.exclusive_queue)))
        lock.exclusive_queue = nil
    end
    lock.name = nil
end

--[[
local TL = new("TestLock")

local function T1(n)
    TRACE("T1", n)
    acquire(TL, {n, "A"})
    TRACE("T2", n)
    if (n == 1) then
        coroutine.yield()
    end
    TRACE("T3", n)
    release(TL, {n})
    TRACE("T4", n)
    release(TL, {"A"})
    TRACE("T5", n)
end

local function T2(n)
    TRACE("t1", n)
    acquire(TL, {shared = true, n, "A"})
    TRACE("t2, n")
    acquire(TL, {shared = true, 1, "B"})
    TRACE("t3, n")
    release(TL, {n, "A"})
    TRACE("t4, n")
    release(TL, {1, "B"})
    TRACE("t5, n")
end

local c = coroutine.create(T1)
coroutine.resume(c, 1)
coroutine.resume(coroutine.create(T1), 2)
coroutine.resume(coroutine.create(T1), 3)
coroutine.resume(coroutine.create(T2), 4)
coroutine.resume(coroutine.create(T2), 5)
coroutine.resume(coroutine.create(T2), 6)
coroutine.resume(coroutine.create(T1), 7)
coroutine.resume(coroutine.create(T1), 8)
coroutine.resume(c)
--]=]

destroy(TL)

TRACE ("EXIT")

--]]

-- module interface
return {
    new = new,
    destroy = destroy,
    acquire = acquire,
    release = release,
    tryacquire = tryacquire,
    blocked_tasks = blocked_tasks,
}

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
