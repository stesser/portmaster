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

local Msg = require("portmaster.msg")
local Param = require("portmaster.param")
local Posix = require("posix")

-- -------------------------
local MOVED_CACHE -- table indexed by old origin (as text) and giving struct with new origin (as text), date and reason for move
local MOVED_CACHE_REV -- table indexed by new origin (as text) giving previous origin (as text)

--
--[[
Cases:
   1) no flavor -> no flavor (non-flavored port)
   2) no flavor -> with flavor (flavors added)
   3) with flavor -> no flavor (flavors removed)
   4) no flavor -> no flavor (flavored port !!!)

Cases 1, 2 and 3 can easily be dealt with by comparing the
full origin with column 1 (table lookup using full origin).

Case 4 cannot be assumed from the origin having or not having
a flavor - and it looks identical to case 1 in the MOVED file.

If the passed in origin contains a flavor, then entries before
the addition of flavors should be ignored, but there is no way
to reliably get the date when flavors were added from the MOVED
file.
--]]

local function moved_cache_load()
    local function register_moved(old, new, date, reason)
        if old then
            local o_p, o_f = string.match(old, "([^@]+)@?([%S]*)")
            local n_p, n_f = string.match(new, "([^@]+)@?([%S]*)")
            o_f = o_f ~= "" and o_f or nil
            n_f = n_f ~= "" and n_f or nil
            if not MOVED_CACHE[o_p] then
                MOVED_CACHE[o_p] = {}
            end
            table.insert(MOVED_CACHE[o_p], {o_p, o_f, n_p, n_f, date, reason})
            if n_p then
                if not MOVED_CACHE_REV[n_p] then
                    MOVED_CACHE_REV[n_p] = {}
                end
                table.insert(MOVED_CACHE_REV[n_p], {o_p, o_f, n_p, n_f, date, reason})
            end
        end
    end

    if not MOVED_CACHE then
        MOVED_CACHE = {}
        MOVED_CACHE_REV = {}
        local filename = path_concat(Param.portsdir, "MOVED") -- allow override with configuration parameter ???
        Msg.show {level = 2, start = true, "Load list of renamed or removed ports from", filename}
        local movedfile = io.open(filename, "r")
        if movedfile then
            for line in movedfile:lines() do
                register_moved(string.match(line, "^([^#][^|]+)|([^|]*)|([^|]+)|([^|]+)"))
            end
            io.close(movedfile)
        end
        Msg.show {level = 2, "The list of renamed or removed ports has been loaded"}
        Msg.show {level = 2, start = true}
    end
end

-- try to find origin in list of moved or deleted ports, returns new origin or nil if found, false if not found, followed by reason text
local function lookup_moved_origin(origin)
    local function o(p, f)
        if p and f then
            p = p .. "@" .. f
        end
        return p
    end
    local function locate_move(p, f, min_i)
        local m = MOVED_CACHE[p]
        if not m then
            return p, f, nil
        end
        local max_i = #m
        local i = max_i
        TRACE("MOVED?", o(p, f), p, f)
        repeat
            local o_p, o_f, n_p, n_f, date, reason = table.unpack(m[i])
            if p == o_p and (not f or not o_f or f == o_f) then
                local p = n_p
                local f = f ~= o_f and f or n_f
                local r = reason .. " on " .. date
                TRACE("MOVED->", o(p, f), r)
                if not p or Posix.access(Param.portsdir .. p .. "/Makefile", "r") then
                    return p, f, r
                end
                return locate_move(p, f, i + 1)
            end
            i = i - 1
        until i < min_i
        return p, f, nil
    end

    if not MOVED_CACHE then
        moved_cache_load()
    end
    local p, f, r = locate_move(origin.port, origin.flavor, 1)
    if r then
        if p then
            origin = Origin:new(o(p, f))
        end
        origin.reason = r -- XXX reason might be set on wrong port (old vs. new???)
        return origin
    end
end

return {
    new_origin = lookup_moved_origin,
}
