--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2021 Stefan EÃŸer <se@freebsd.org>

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
-- split string on line boundaries and return as table
local function split_lines(str)
    local result = {}
    for line in string.gmatch(str, "([^\n]*)\n?") do
        table.insert(result, line)
    end
    return result
end

-- split string on word boundaries and return as table
local function split_words(str)
    if str then
        local result = {}
        for word in string.gmatch(str, "%S+") do
            table.insert(result, word)
        end
        return result
    end
end

-- remove trailing new-line, if any (UTIL)
local function chomp(str)
    if str and str:byte(-1) == 10 then
        return str:sub(1, -2)
    end
    return str
end

-- test whether the second parameter is a prefix of the first parameter (UTIL)
local function strpfx(str, pattern)
    return str:sub(1, #pattern) == pattern
end

return {
	split_lines = split_lines,
	split_words = split_words,
	chomp = chomp,
	strpfx = strpfx,
}
