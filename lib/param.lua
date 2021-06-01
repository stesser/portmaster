--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019, 2021 Stefan Eßer <se@freebsd.org>

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
--local Trace = require("portmaster.trace")
local Filepath = require("portmaster.filepath")

-------------------------------------------------------------------------------------
--local TRACE = Trace.trace

local geteuid = P.geteuid
local getpwuid = P.getpwuid
--local access = P.access
local ttyname = P.ttyname

local Param = {}

local globalmakedirvars = {
        "LOCALBASE",
        "PORTSDIR",
        "DISTDIR",
        "PACKAGES",
        "PKG_DBDIR",
        "PORT_DBDIR",
        "WRKDIRPREFIX",
}

local globalmakevars = {
        "DISABLE_LICENSES",
        "TRY_BROKEN",
        "DISABLE_MAKE_JOBS",
}

local function __index(param, k)
    local function __globalmakevars()
        local pipe = io.popen(CMD.make .. " -f /usr/share/mk/bsd.port.mk -V " .. table.concat(globalmakedirvars, " -V "))
        for _, v in ipairs(globalmakedirvars) do
            Param[string.lower(v)] = Filepath:new(pipe:read("*l"))
        end
        pipe:close()
        pipe = io.popen(CMD.make .. " -f /usr/share/mk/bsd.port.mk -V " .. table.concat(globalmakevars, " -V "))
        for _, v in ipairs(globalmakevars) do
            Param[string.lower(v)] = pipe:read("*l")
        end
        pipe:close()
        return Param[k]
    end

    local function __local_lib()
        return Param.localbase + "lib"
        --return path_concat(Param.localbase, "lib")
    end

    local function __local_lib_compat()
        return Param.local_lib + "compat" + "pkg"
        --return path_concat(Param.local_lib, "compat/pkg")
    end

    local function __jailbase()
    return -- "/tmp/PMJAIL"
    end

    local function __packages_backup()
    return Filepath:new("/usr/packages/portmaster-backup")
    end

    local function __tmpdir()
    return Filepath:new(os.getenv("TMPDIR") or "/tmp")
    end

    local function __distdir_ro()
        return not Param.distdir.is_writeable
    --return not access(Param.distdir, "rw")
    end

    local function __packages_ro()
        return not Param.packages.is_writeable
        --return not access(Param.packages, "rw")
    end

    local function __pkg_dbdir_ro()
        return not Param.port_dbdir.is_writeable
        --return not access(Param.port_dbdir, "rw")
    end

    local function __port_dbdir_ro()
        return not Param.pkg_dbdir.is_writeable
        --return not access(Param.pkg_dbdir, "rw")
    end

    local function __wrkdir_ro()
        return not Param.pkg_wrkdir.is_writeable
        --return not access(Param.pkg_wrkdir, "rw")
    end

    local function __systemabi()
        local pipe = io.popen(CMD.pkg .. " config abi") -- do not rely on Exec.pkg!!!
        local abi = pipe:read("*l")
        pipe:close()
        param.abi_noarch = string.match(abi, "^[%a]+:[%d]+:") .. "*"
        param.abi = abi
        return param[k]
    end

    local function __package_fmt()
        return "tbz" -- only used as fallback default value
    end

    local function __backup_fmt()
        return "tbz" -- only used as fallback default value
    end

    local function __tty_columns()
        if ttyname(0) then
            local pipe = io.popen(CMD.stty .. " size") -- do not rely on Exec.pkg!!!
            local lines = pipe:read("*n")
            local columns = pipe:read("*n")
            pipe:close()
            return columns
        end
    end

    local function __ncpu()
        local ncpu = tonumber(os.getenv("_SMP_CPUS"))
        if not ncpu then
            local pipe = io.popen(CMD.sysctl .. " -n hw.ncpu") -- do not rely on Exec.pkg!!!
            ncpu = pipe:read("*n")
            pipe:close()
        end
        return ncpu
    end

    -- maximum number of make jobs - twice the number of CPU threads?
    local function __maxjobs()
        local overcommit = 1
        local offset = 2
        return math.floor(__ncpu() * overcommit + offset)
    end

    local function __uid()
        return geteuid()
    end

    local function __user()
        local pw_entry = getpwuid(param.uid)
        param.user = pw_entry.pw_name
        param.home = Filepath:new(pw_entry.pw_dir)
        return param[k]
    end

    local dispatch = {
        abi = __systemabi,
        abi_noarch = __systemabi,
        backup_format = __backup_fmt,
        columns = __tty_columns,
        disable_licenses = __globalmakevars,
        distdir_ro = __distdir_ro,
        home = __user,
        ncpu = __ncpu,
        maxjobs = __maxjobs,
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

    --TRACE("INDEX(param)", )
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
        --TRACE("INDEX(param)->", param, k, w)
    else
        --TRACE("INDEX(param)->", param, k, w, "(cached)")
    end
    return w
end

setmetatable(Param, {__index = __index})

return Param
