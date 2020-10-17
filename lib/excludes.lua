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

-------------------------------------------------------------------------------------
--
local EXCLUDED_PKG = {}
local EXCLUDED_PKG_PREFIX = {}
local EXCLUDED_PORT = {}
local EXCLUDED_PORT_PREFIX = {}

--
local function add_pkg(pkg)
    --TRACE("EXCLUDES_ADD_PKG", pkg)
    if (string.match(pkg, "%*$")) then
        table.insert(EXCLUDED_PKG_PREFIX, string.sub(pkg, 1, -2))
    else
        table.insert(EXCLUDED_PKG, pkg)
    end
end

--
local function add_port(port)
    --TRACE("EXCLUDES_ADD_PORT", port)
    if (string.match(port, "%*$")) then
        table.insert(EXCLUDED_PORT_PREFIX, string.sub(port, 1, -2))
    else
        table.insert(EXCLUDED_PORT, port)
    end
end

--
local function add(port_or_pkg)
    --TRACE("EXCLUDES_ADD", port_or_pkg)
    if string.match(port_or_pkg, "/") then
        add_port(port_or_pkg)
    else
        add_pkg(port_or_pkg)
    end
end

--
local function check_pkg(pkg)
    --TRACE("EXCLUDES_CHK_PKG", pkg.name)
    local basename = pkg.name_base
    for i, v in ipairs(EXCLUDED_PKG) do
        --TRACE("EXCLUDE_CHK", v, pkg.name)
        if basename == v then
            --TRACE("EXCLUDED", v, pkg.name)
            return true
        end
    end
    for i, v in ipairs(EXCLUDED_PKG_PREFIX) do
        --TRACE("EXCLUDE_CHK", v, pkg.name)
        if string.sub(pkg.name, 1, #v) == v then
            --TRACE("EXCLUDED", v, pkg.name)
            return true
        end
    end
end

--
local function check_port(port)
    --TRACE("EXCLUDES_CHK_PORT", port.name)
    for i, v in ipairs(EXCLUDED_PORT) do
        --TRACE("EXCLUDE_CHK", v, port.name)
        if port == v then
            --TRACE("EXCLUDED", v, port.name)
            return true
        end
    end
    for i, v in ipairs(EXCLUDED_PORT_PREFIX) do
        --TRACE("EXCLUDE_CHK", v, port.name)
        if string.sub(port, 1, #v) == v then
            --TRACE("EXCLUDED", v, port.name)
            return true
        end
    end
end

--
local function list()
    local result = EXCLUDED_PKG
    -- table.move (EXCLUDED_PORT, 1, #EXCLUDED_PORT, #result + 1, result) -- lua53 only
    for i, v in ipairs(EXCLUDED_PKG_PREFIX) do
        table.insert(result, v .. "*")
    end
    for i, v in ipairs(EXCLUDED_PORT) do
        table.insert(result, v)
    end
    for i, v in ipairs(EXCLUDED_PORT_PREFIX) do
        table.insert(result, v .. "*")
    end
    --TRACE("EXCLUDES_LIST", result)
    return result
end

-- module interface
return {
    add = add,
    add_pkg = add_pkg,
    add_port = add_port,
    check_pkg = check_pkg,
    check_port = check_port,
    list = list,
}
