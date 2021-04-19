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
local P_SL = require("posix.stdlib")
local setenv = P_SL.setenv

local P_US = require("posix.unistd")
local getpid = P_US.getpid

local Param = require("portmaster.param")
local CMD = require("portmaster.cmd")
local Trace = require("portmaster.trace")

-------------------------------------------------------------------------------------
local TRACE = Trace.trace

-------------------------------------------------------------------------------------
-- set sane defaults and cache some buildvariables in the environment
local function init()
    setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin:" .. Param.localbase .. "/bin:" .. Param.localbase .. "/sbin")
    setenv("PID", getpid())
    setenv("LANG", "C")
    setenv("LC_CTYPE", "C")
    setenv("CASE_SENSITIVE_MATCH", "yes")
    setenv("LOCK_RETRIES", "120")
    setenv("DEV_WARNING_WAIT", "0") -- prevent delays for messages that are not displayed, anyway
    local portsdir = Param.portsdir
    local scriptsdir = path_concat(portsdir, "Mk/Scripts")
    local envvars = "SCRIPTSDIR='" .. scriptsdir .. "' PORTSDIR='" .. portsdir .. "' MAKE='" .. CMD.make .. "'"
    local cmdline = table.concat({CMD.env, envvars, CMD.sh, path_concat(scriptsdir, "ports_env.sh")}, " ")
    local pipe = io.popen(cmdline)
    for line in pipe:lines() do
        local var, value = line:match("^export ([%w_]+)=(.+)")
        if string.sub(value, 1, 1) == '"' and string.sub(value, -1) == '"' then
            value = string.sub(value, 2, -2)
        end
        --TRACE("SETENV", var, value)
        setenv(var, value)
    end
    pipe:close()
end

return {
    init = init
}
