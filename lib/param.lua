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
local P = require("posix")

local geteuid = P.geteuid
local getpwuid = P.getpwuid
local access = P.access
local ttyname = P.ttyname

local Param = {}

local globalmakevars = {
        "LOCALBASE",
        "PORTSDIR",
        "DISTDIR",
        "PACKAGES",
        "PKG_DBDIR",
        "PORT_DBDIR",
        "WRKDIRPREFIX",
        "DISABLE_LICENSES",
}

local function __globalmakevars(param, k)
    local pipe = io.popen(CMD.make .. " -f /usr/share/mk/bsd.port.mk -V " .. table.concat(globalmakevars, " -V "))
    for _, v in ipairs(globalmakevars) do
        Param[string.lower(v)] = pipe:read("*l")
    end
    pipe:close()
    return Param[k]
end

local function __local_lib(param, k)
   return path_concat(Param.localbase, "lib")
end

local function __local_lib_compat(param, k)
   return path_concat(Param.local_lib, "compat/pkg")
end

local function __jailbase(param, k)
   return -- "/tmp/PMJAIL"
end

local function __packages_backup(param, k)
   return "/usr/packages/portmaster-backup"
end

local function __tmpdir(param, k)
   return os.getenv("TMPDIR") or "/tmp"
end

local function __distdir_ro(param, k)
   return not access(Param.distdir, "rw")
end

local function __packages_ro(param, k)
   return not access(Param.packages, "rw")
end

local function __pkg_dbdir_ro(param, k)
   return not access(Param.port_dbdir, "rw")
end

local function __port_dbdir_ro(param, k)
   return not access(Param.pkg_dbdir, "rw")
end

local function __wrkdir_ro(param, k)
   return not access(Param.pkg_wrkdir, "rw")
end

local function __systemabi(param, k)
    local pipe = io.popen(CMD.pkg .. " config abi") -- do not rely on Exec.pkg!!!
    local abi = pipe:read("*l")
    pipe:close()
    param.abi_noarch = string.match(abi, "^[%a]+:[%d]+:") .. "*"
    param.abi = abi
    return param[k]
end

local function __package_fmt(param, k)
    return "tbz" -- only used as fallback
end

local function __backup_fmt(param, k)
    return "tbz" -- only used as fallback
end

local function __tty_columns(param, k)
    if ttyname(0) then
	local pipe = io.popen(CMD.stty .. " size") -- do not rely on Exec.pkg!!!
	local lines = pipe:read("*n")
	local columns = pipe:read("*n")
	pipe:close()
	return columns
    end
end

local function __ncpu(param, k)
    local pipe = io.popen(CMD.sysctl .. " -n hw.ncpu") -- do not rely on Exec.pkg!!!
    local ncpu = pipe:read("*n")
    pipe:close()
    return ncpu
end

local function __uid(param, k)
    return geteuid()
end

local function __user(param, k)
    local pw_entry = getpwuid(param.uid)
    param.user = pw_entry.pw_name
    param.home = pw_entry.pw_dir
    return param[k]
end

local function __index(param, k)
    local dispatch = {
        abi = __systemabi,
        abi_noarch = __systemabi,
        backup_format = __backup_fmt,
        columns = __tty_columns,
        disable_licenses = __globalmakevars,
        distdir_ro = __distdir_ro,
        home = __user,
        ncpu = __ncpu,
        package_format = __package_fmt,
        packages_ro = __packages_ro,
        pkg_dbdir_ro = __pkg_dbdir_ro,
        port_dbdir_ro = __port_dbdir_ro,
        uid = __uid,
        user = __user,
        wrkdir_ro = __wrkdir_ro,
        distdir = __globalmakevars,
        jailbase = __jailbase,
        local_lib = __local_lib,
        local_lib_compat = __local_lib_compat,
        localbase = __globalmakevars,
        packages = __globalmakevars,
        packages_backup = __packages_backup,
        pkg_dbdir = __globalmakevars,
        port_dbdir = __globalmakevars,
        portsdir = __globalmakevars,
        tmpdir = __tmpdir,
        wrkdirprefix = __globalmakevars,
    }

    TRACE("INDEX(param)", param, k)
    local w = rawget(param, k)
    if w == nil then
        rawset(param, k, false)
        local f = dispatch[k]
        if f then
            w = f(param, k)
            if w then
                rawset(param, k, w)
            else
                w = false
            end
        --else
            -- error("illegal field requested: Package." .. k)
        end
        TRACE("INDEX(param)->", param, k, w)
    else
        TRACE("INDEX(param)->", param, k, w, "(cached)")
    end
    return w
end

setmetatable(Param, {__index = __index})

return Param
