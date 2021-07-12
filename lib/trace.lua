--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019-2021 Stefan EÃŸer <se@freebsd.org>

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
local Util = require("portmaster.util")

-------------------------------------------------------------------------------------
local table_expand_level = 4 -- 3
local STARTTIMESECS = os.time()
local tracefd

local FunctionTable = {}

local function trace(...)
    local function as_string(v)
        if type(v) == "function" then
            local f = FunctionTable[v]
            if not f then
                local info = debug.getinfo(v, "S")
                local module = string.match(info.short_src, "[^/]*$")
                f = module .. ":" .. info.linedefined
                FunctionTable[v] = f
                --trace("GETINFO", tostring(v), info)
            end
            return f or tostring(v)
        end
        v = tostring(v)
        if v == "" or string.find(v, " ") then
            return "'" .. v .. "'"
        end
        return v
    end
    local function table_to_string(t, level, indent)
        if level <= 0 then
            return tostring(t)
        end
        local indent2 = indent .. " "
        local result = {}
        local top_level = true
        local function table_entry(k)
            if type(k) ~= "string" or string.sub(k, 1, 1) ~= "_" then
                local v = t[k]
                top_level = top_level and not (type(k) == "table" or type(v) == "table")
                k = type(k) == "table" and table_to_string(k, 1, "") or as_string(k)
                v = type(v) == "table" and table_to_string(v, level - 1, indent2) or as_string(v)
                result[#result + 1] = k .. " = " .. v
            end
        end
        local kt = Util.table_keys(t)
        table.sort(kt, function (a,b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(kt) do
            table_entry(k)
        end
        for i = 1, #t do
            table_entry(i)
        end
        if #result == 0 then
            return "{}"
        elseif #result == 1 or top_level and #result <= 4 then
            return "{" .. table.concat(result, ", ") .. "}"
        else
            return "{\n" .. indent2 .. table.concat(result, ",\n" .. indent2) .. "\n" .. indent .. "}"
        end
    end
    if tracefd then
        local t = {...}
        local sep = ""
        local tracemsg = ""
        for i = 1, #t do
            local v
            if type(t[i]) == "table" then
                v = table_to_string(t[i], table_expand_level, " ")
            else
                v = as_string(t[i])
            end
            tracemsg = tracemsg .. sep .. v
            sep = " "
        end
        local dbginfo = debug.getinfo(3, "Sl") or debug.getinfo(2, "Sl")
        tracefd:write(tostring(os.time() - STARTTIMESECS) .. "	" .. (dbginfo.short_src or "(main)") .. ":" ..
                          dbginfo.currentline .. "\t" .. tracemsg .. "\n")
        tracefd:flush()
    end
end

-------------------------------------------------------------------------------------
local trace_filename

local function init(filename, table_expand)
	if trace_filename ~= filename then
		if tracefd then
			tracefd:close()
			tracefd = nil
		end
		if filename then
			tracefd = io.open(filename, "w")
		end
		trace_filename = filename
	end
	if table_expand then
		table_expand_level = table_expand
	end
end

-------------------------------------------------------------------------------------
return {
	trace = trace,
	init = init,
}
