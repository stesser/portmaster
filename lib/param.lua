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
-- local Origin = require ("portmaster.origin")
--local Options = require("portmaster.options")
local PATH = require("portmaster.path")
local CMD = require("portmaster.cmd")
local P = require("posix")

local geteuid = P.geteuid
local getpwuid = P.getpwuid
local access = P.access
local ttyname = P.ttyname

--[[
TRACE = print

function table:keys()
    local result = {}
    for k, _ in pairs(self) do
        if type(k) ~= "number" then
            table.insert(result, k)
        end
    end
    return result
end

local PATH = {
    distdir = "/usr/ports/distfiles",
    jailbase = "/tmp/PMJAIL",
    local_lib = "/usr/local/lib",
    local_lib_compat = "/usr/local/lib/compat/pkg",
    localbase = "/usr/local",
    packages = "/usr/packages",
    packages_backup = "/usr/packages/portmaster-backup",
    pkg_dbdir = "/var/db/pkg",
    port_dbdir = "/var/db/port",
    portsdir = "/usr/ports",
    tmpdir = "/tmp",
    wrkdirprefix = "/usr/work",
}

CMD = {
    pkg = "/usr/local/sbin/pkg-static",
    stty = "/bin/stty",
    sysctl = "/sbin/sysctl"
}
--]]

local function __systemabi(param, k)
    local pipe = io.popen(CMD.pkg .. " config abi") -- do not rely on Exec.pkg!!!
    local abi = pipe:read("*l")
    pipe:close()
    param.abi_noarch = string.match(abi, "^[%a]+:[%d]+:") .. "*"
    param.abi = abi
    TRACE("SYSTEM_ABI", param.abi, param.abi_noarch)
    return param[k]
end

local function __package_fmt(param, k)
    param.package_fmt = Options.package_fmt
    param.backup_fmt = Options.backup_fmt
    return param[k]
end

local function __tty_columns(param, k)
    if ttyname(0) then
	local pipe = io.popen(CMD.stty .. " size") -- do not rely on Exec.pkg!!!
	local lines = pipe:read("*n")
	local columns = pipe:read("*n")
	pipe:close()
	TRACE("L/C", lines, columns)
	return columns
    end
end

local function __disable_licenses(param, k)
    local pipe = io.popen(CMD.make .. " -f /usr/share/mk/bsd.port.mk -V DISABLE_LICENSES") -- do not rely on Exec.pkg!!!
    local disable_licenses = pipe:read("*l")
    pipe:close()
    return disable_licenses
end

local function __distdir_ro(param, k)
   return not access(PATH.distdir, "rw")
end

local function __ncpu(param, k)
    local pipe = io.popen(CMD.sysctl .. " -n hw.ncpu") -- do not rely on Exec.pkg!!!
    local ncpu = pipe:read("*n")
    pipe:close()
    TRACE("NCPU", ncpu)
    return ncpu
end

local function __packages_ro(param, k)
   return not access(PATH.packages, "rw")
end

local function __pkg_dbdir_ro(param, k)
   return not access(PATH.port_dbdir, "rw")
end

local function __port_dbdir_ro(param, k)
   return not access(PATH.pkg_dbdir, "rw")
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

local function __wrkdir_ro(param, k)
   return not access(PATH.pkg_wrkdir, "rw")
end

local function __jailbase(param, k)
    return -- "/tmp/PM_JAIL"
end

local function __index(param, k)
    local dispatch = {
	abi = __systemabi,
	abi_noarch = __systemabi,
	backup_format = __package_fmt,
	columns = __tty_columns,
	disable_licenses = __disable_licenses,
	distdir_ro = __distdir_ro,
	home = __user,
	jailbase = __jailbase,
	ncpu = __ncpu,
	package_format = __package_fmt,
	packages_ro = __packages_ro,
	pkg_dbdir_ro = __pkg_dbdir_ro,
	port_dbdir_ro = __port_dbdir_ro,
	uid = __uid,
	user = __user,
	wrkdir_ro = __wrkdir_ro,
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
        else
            -- error("illegal field requested: Package." .. k)
        end
        TRACE("INDEX(param)->", param, k, w)
    else
        TRACE("INDEX(param)->", param, k, w, "(cached)")
    end
    return w
end

local Param = {}
setmetatable(Param, {__index = __index})

return Param

--[[
PARAM = Param

print (Param.user, Param.home, Param.distdir_ro)
print (Param.abi, Param.abi_noarch)
print (Param.columns)
print (Param.ncpu)
--]]
