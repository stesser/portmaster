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
local function new(name)
    local lock = {__name = name}
    return lock
end

local function tryacquire(lock, item)
    assert(lock and lock.__name, "Attempt to acquire lock using an unitialized lock structure for " .. item)
    if lock[item] then
        return false
    else
        TRACE("LOCK_ACQUIRE", lock.__name, item)
        lock[item] = {} -- create empty wait table to signal that lock has been acquired -- set lock owner???
        return true
    end
end

--
local function acquire(lock, item)
    local co, in_main = coroutine.running()
    assert(not in_main, "Attempt to use lock outside of coroutine")
    if not tryacquire(lock, item) then
        TRACE("LOCK_WAIT", lock.__name, item, co)
        table.insert(lock[item], co) -- enter current coroutine into wait table
        return coroutine.yield()
    end
end

--
local function release(lock, item)
    assert(lock, "Attempt to release lock using an unitialized lock structure for " .. (item or "<nil>"))
    local l = lock[item]
    local co = table.remove(l, 1)
    TRACE("LOCK_RELEASE", lock.__name, item, co)
    if co then
        TRACE("LOCK_RESUME", co, coroutine.status(co))
        return coroutine.resume(co)
    else
        lock[item] = nil
        TRACE("LOCK_CLEAR", lock.__name, item)
    end
end

--[[
local TL = new("TestLog")

local function T(n)
    TRACE("T1", n)
    acquire(TL, "A")
    TRACE("T2", n)
    if (n == 1) then
        coroutine.yield()
    end
    TRACE("T3", n)
    release(TL, "A")
    TRACE("T4", n)
end

local c1 = coroutine.create(T)
coroutine.resume(c1, 1)
local c2 = coroutine.create(T)
coroutine.resume(c2, 2)
local c3 = coroutine.create(T)
coroutine.resume(c3, 3)
coroutine.resume(c1)
TRACE ("EXIT")
--]]

-- module interface
return {
    new = new,
    acquire = acquire,
    release = release,
    tryacquire = tryacquire,
}
