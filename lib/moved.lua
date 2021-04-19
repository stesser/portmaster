--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019-2021 Stefan Eßer <se@freebsd.org>

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

-- ToDo: integrate back into Origin module

-------------------------------------------------------------------------------------
local Msg = require("portmaster.msg")
local Param = require("portmaster.param")
local Posix = require("posix")
local Origin = require("portmaster.origin")
local Trace = require("portmaster.trace")

-------------------------------------------------------------------------------
local TRACE = Trace.trace

-------------------------------------------------------------------------------------
local MOVED_CACHE  -- table indexed by old origin (as text) and giving struct with new origin (as text), date and reason for move
local MOVED_CACHE_REV  -- table indexed by new origin (as text) giving previous origin (as text)

--[[
Cases:
   1) no flavor -> no flavor (non-flavored port)
   2) no flavor -> with flavor (flavors added)
   3) with flavor -> no flavor (flavors removed)
   4) no flavor -> no flavor (flavored port !!!)

Cases 1, 2 and 3 can easily be dealt with by comparing the
full origin with column 1 (table lookup using full origin).

Case 4 cannot be guessed from the origin having or not having
a flavor - and it looks identical to case 1 in the MOVED file.

If the passed-in origin contains a flavor, then entries before
the addition of flavors should be ignored, but there is no way
to reliably determjne the date when flavors were from the data
in the MOVED file.

MOVED_CACHE[port_old]     -> array of {port_old, flavor_old, port_new, flavor_new, date, reason}
MOVED_CACHE_REV[port_new] -> array of {port_old, flavor_old, port_new, flavor_new, date, reason}
--]]

local function moved_cache_load()
    local function register_moved(old, new, date, reason)
        if old then
            local o_p, o_f = string.match(old, "^([^@]+)@?([^:%%]*)")
            --TRACE("REGISTER_MOVED(old)", old, o_p, o_f)
            local n_p, n_f = string.match(new, "^([^@]+)@?([^:%%]*)")
            --TRACE("REGISTER_MOVED(new)", new, n_p, n_f)
            o_f = o_f ~= "" and o_f or nil
            n_f = n_f ~= "" and n_f or nil
            local record = {o_p, o_f, n_p, n_f, date, reason}
            local mc = MOVED_CACHE[o_p] or {}
            mc[#mc + 1] = record
            MOVED_CACHE[o_p] = mc
            if n_p then
                local mcr = MOVED_CACHE_REV[n_p] or {}
                mcr[#mcr + 1] = record
                MOVED_CACHE_REV[n_p] = mcr
            end
        end
    end

    if not MOVED_CACHE then
        MOVED_CACHE = {}
        MOVED_CACHE_REV = {}
        local filename = path_concat(Param.portsdir, "MOVED") -- allow override with configuration parameter ???
        local movedfile = io.open(filename, "r")
        if movedfile then
            Msg.show {level = 2, start = true, "Load list of renamed or removed ports from", filename}
            for line in movedfile:lines() do
                register_moved(string.match(line, "^([^#][^|]+)|([^|]*)|([^|]+)|([^|]+)"))
            end
            io.close(movedfile)
            Msg.show {level = 2, "The list of renamed or removed ports has been loaded"}
            Msg.show {level = 2, start = true}
        end
    end
end

-- combine port and flavor to get origin
local function o(port, flavor)
    if port and flavor then
        port = port .. "@" .. flavor
    end
    return port
end

-- try to find origin in list of moved or deleted ports, returns new origin or nil if found, false if not found, followed by reason text
local function lookup_new_origin(origin)
    local function locate_move(port, flavor, min_i)
        local movedrec = MOVED_CACHE[port]
        if not movedrec then
            return port, flavor, nil
        end
        local max_i = #movedrec
        --TRACE("MOVED?", o(port, flavor), port, flavor, min_i, max_i)
        for i = max_i, min_i, -1 do
            local o_p, o_f, n_p, n_f, date, reason = table.unpack(movedrec[i])
            if port == o_p and (not flavor or not o_f or flavor == o_f) then
                local newport = n_p
                local newflavor = flavor ~= o_f and flavor or n_f
                local r = date .. ": " .. reason
                --TRACE("MOVED->", o(newport, newflavor), r)
                local path = path_concat(Param.portsdir, newport, "Makefile")
                if not newport or Posix.access(path, "r") then
                    return newport, newflavor, r
                end
                return locate_move(newport, newflavor, i + 1)
            end
        end
        return port, flavor, nil
    end

    if not MOVED_CACHE then
        moved_cache_load()
    end
    local origin_0 = origin
    local port, flavor, r = locate_move(origin.port, origin.flavor, 1)
    if r then
        origin_0.reason = r -- XXX reason might be set on wrong port (old vs. new???)
        if port then
            return Origin:new(o(port, flavor))
        end
    end
end

--
local function lookup_prev_origin(origin)
    local function locate_rev_move(port, flavor, min_i)
        local movedrec = MOVED_CACHE_REV[port]
        if not movedrec then
            return port, flavor, nil
        end
        local max_i = #movedrec
        --TRACE("REV_MOVED?", o(port, flavor), port, flavor, min_i, max_i)
        for i = max_i, min_i, -1 do
            local o_p, o_f, n_p, n_f, date, reason = table.unpack(movedrec[i])
            if port == n_p and (not flavor or not n_f or flavor == n_f) then
                local prevport = o_p
                local prevflavor = flavor ~= n_f and flavor or o_f
                local r = reason .. " on " .. date
                --TRACE("REV_MOVED->", o(prevport, prevflavor), r)
                if not prevport then
                    return false, false, nil
                end
                local prev_origin = Origin.get(o(prevport, prevflavor))
                if prev_origin then
                    return prevport, prevflavor, r
                end
                return locate_rev_move(prevport, prevflavor, i + 1)
            end
        end
        return port, flavor, nil
    end

    if not MOVED_CACHE_REV then
        moved_cache_load()
    end
    local port, flavor, r = locate_rev_move(origin.port, origin.flavor, 1)
    --if r then
        if port then
            origin = Origin.get(o(port, flavor))
        end
        origin.reason = r -- XXX reason might be set on wrong port (old vs. new???)
        return origin
    --end
end

--
return {
    new_origin = lookup_new_origin,
    prev_origin = lookup_prev_origin,
}
