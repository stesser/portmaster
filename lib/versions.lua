--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2021 Stefan Eßer <se@freebsd.org>

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
local Trace = require("portmaster.trace")

-------------------------------------------------------------------------------------
local TRACE = Trace.trace

--
local special_revs = {pl = true, alpha = true, beta = true, pre = true, rc = true}
local special_vals = {["*"] = -2, pl = -1, [""] = 0}

local function split_version_string(pkgname)
    local function alpha_tonumber(s)
        s = string.lower(s)
        return special_vals[s] or string.byte(s, 1, 1) - 96 -- subtract one less than ASCII "a" == 0x61 == 97
    end
    local result = {}
    local function store_results(n1, a1, n2)
        local rn = #result
        --TRACE("SPLIT_VERSION-STORE_RESULTS", n1, a1, n2)
        result[rn+1] = n1 ~= "" and tonumber(n1) or -1
        result[rn+2] = alpha_tonumber(a1)
        result[rn+3] = n2 ~= "" and tonumber(n2) or 0
    end
    local version = string.match(pkgname, "[%a%d%._,]*%*?$")
    --TRACE("SPLIT_VERSION_STRING", pkgname, version)
    local s, revision, epoch = string.match (version, "([^_,]*)_?([^,]*),?(.*)")
    version = s or version
    for n1, a1, n2 in string.gmatch(version, "(%d*)([%a%*]*)(%d*)") do
        if special_revs[a1] then
            store_results(n1, "", "")
            n1 = ""
        end
        store_results(n1, a1, n2)
    end
    result.epoch = tonumber(epoch) or 0
    result.revision = tonumber(revision) or 0
    --TRACE("SPLIT_VERSION_STRING->", result)
    return result
end

-- return 0 for v1 == v2, positive result for v1 higher than v2, negative result else
local function compare_versions(p1, p2)
    local function compare_lists(t1, t2)
        local n1 = #t1
        local n2 = #t2
        local n = n1 > n2 and n1 or n2
        for i = 1, n do
            local delta = (t1[i] or 0) - (t2[i] or 0)
            if delta ~= 0 then
                return delta
            end
        end
        return 0
    end
    --TRACE("COMPARE_VERSIONS", p1 and p1.name, p2 and p2.name)
    if p1 and p2 then
        local result = 0
        local vs1 = p1.version
        local vs2 = p2.version
        if vs1 ~= vs2 then
            local v1 = split_version_string(vs1)
            local v2 = split_version_string(vs2)
            result = v1.epoch - v2.epoch
            if result == 0 then
                result = compare_lists(v1, v2)
                if result == 0 then
                    result = v1.revision - v2.revision
                end
            end
        end
        TRACE("COMPARE_VERSIONS->", p1 and p1.name, p2 and p2.name, result)
        return result
    end
end

return {
	compare = compare_versions,
}
