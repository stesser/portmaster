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
local CMD = require("portmaster.cmd")

local Path = {}

local pathvars = {
        "LOCALBASE",
        "PORTSDIR",
        "DISTDIR",
        "PACKAGES",
        "PKG_DBDIR",
        "PORT_DBDIR",
        "WRKDIRPREFIX",
}

local function __globalpaths(param, k)
    local pipe = io.popen(CMD.make .. " -f /usr/share/mk/bsd.port.mk -V " .. table.concat(pathvars, " -V "))
    for _, v in ipairs(pathvars) do
        Path[string.lower(v)] = pipe:read("*l")
    end
    pipe:close()
    return Path[k]
end

local function __local_lib(path, k)
   return path_concat(Path.localbase, "lib")
end

local function __local_lib_compat(path, k)
   return path_concat(Path.local_lib, "compat/pkg")
end

local function __jailbase(path, k)
   return -- "/tmp/PMJAIL"
end

local function __packages_backup(path, k)
   return "/usr/packages/portmaster-backup"
end

local function __tmpdir(path, k)
   return os.getenv("TMPDIR") or "/tmp"
end

local function __index(path, k)
    local dispatch = {
        distdir = __globalpaths,
        jailbase = __jailbase,
        local_lib = __local_lib,
        local_lib_compat = __local_lib_compat,
        localbase = __globalpaths,
        packages = __globalpaths,
        packages_backup = __packages_backup,
        pkg_dbdir = __globalpaths,
        port_dbdir = __globalpaths,
        portsdir = __globalpaths,
        tmpdir = __tmpdir,
        wrkdirprefix = __globalpaths,
    }

    TRACE("INDEX(path)", path, k)
    local w = rawget(path, k)
    if w == nil then
        rawset(path, k, false)
        local f = dispatch[k]
        if f then
            w = f(path, k)
            if w then
                rawset(path, k, w)
            else
                w = false
            end
        else
            -- error("illegal field requested: Package." .. k)
        end
        TRACE("INDEX(path)->", path, k, w)
    else
        TRACE("INDEX(path)->", path, k, w, "(cached)")
    end
    return w
end

setmetatable(Path, {__index = __index})

return Path
