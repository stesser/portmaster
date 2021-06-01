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
--[[
local Origin = require ("portmaster.origin")
local Excludes = require("portmaster.excludes")
local Options = require("portmaster.options")
local PkgDb = require("portmaster.pkgdb")
local Msg = require("portmaster.msg")
local Exec = require("portmaster.exec")
local CMD = require("portmaster.cmd")
local Param = require("portmaster.param")
--]]
local Trace = require("portmaster.trace")

-------------------------------------------------------------------------------------
local P = require("posix")
local glob = P.glob

local P_SS = require("posix.sys.stat")
local stat = P_SS.stat
local lstat = P_SS.lstat
local stat_isdir = P_SS.S_ISDIR
local stat_isreg = P_SS.S_ISREG

local P_US = require("posix.unistd")
local access = P_US.access

local TRACE = Trace.trace

local Filepath = {}

-------------------------------------------------------------------------------------
-- concatenate file path, first element must not be empty
local function path_concat(result, ...)
    --TRACE("PATH_CONCAT", result, ...)
    if result ~= "" then
        for _, v in ipairs({...}) do
            local sep = string.sub(result, -1) ~= "/" and string.sub(v, 1, 1) ~= "/" and "/" or ""
            result = result .. sep .. v
        end
        --TRACE("PATH_CONCAT->", result)
        return result
    end
end

-- go directory levels up
local function path_up(dir, level)
    local result = dir.name
    level = level or 1
    for _ = 1, level do
        if result == "/" then
                break
        end
        result = string.gsub(result, "/[^/]+$", "")
    end
    return Filepath:new(result)
end

--
local function open()

end

--
local function close()

end

--
local function delete(filepath)
    local filename = filepath.name
    if filename then
        P.unlink(filename)
    end
end

--
local function add(dir, ...)
    --TRACE("ADD", dir, ...)
    return Filepath:new(path_concat(dir.name, ...))
end

--
local function is_dir(name)
    TRACE("IS_DIR?", name)
    local st, err = lstat(name)
    --TRACE("IS_DIR->", name, st, err)
    if st and access(name, "x") then
        --TRACE("IS_DIR", path, stat_isdir(st.st_mode))
        return stat_isdir(st.st_mode) ~= 0
    end
    return false
end

Filepath.is_dir = is_dir

-------------------------------------------------------------------------------------
local function __index(path, k)
    local function __is_dir()
        return is_dir(path.name)
    end
    local function __readable()
        local name = path.name
        if name and name ~= "" then
            return access(name, "r") == 0
        end
    end
    local function __writeable()
        local name = path.name
        if name and name ~= "" then
            return access(name, "w") == 0
        end
    end
    local function __deleteable()

    end
    local function __files()
        local name = path.name
        if path.is_dir then
            name = name .. "/*"
        end
        return glob(name, 0) -- or {} ???
    end
    local function __add()
        return add
    end
    local function __sub()
        return path_up
    end
    local dispatch = {
        is_dir = __is_dir,
        is_readable = __readable,
        is_writeable = __writeable,
        is_deleteable = __deleteable,
        files = __files,
        add = __add,
        sub = __sub,
    }

    --TRACE("INDEX(f)", rawget(path, "name"), k)
    local w = false
    local f = dispatch[k]
    if f then
        w = f()
    else
        error("illegal field requested: Filepath." .. k)
    end
    TRACE("INDEX(f)->", rawget(path, "name"), k, w)
    return w
end

--
local mt = {
    __index = __index,
    --__newindex = __newindex, -- DEBUGGING ONLY
    __add = add,
    __sub = path_up,
    __tostring = function(self)
        return self.name
    end,
}

--
function Filepath.new(Filepath, name)
    if name then
        local F = {name = name}
        F.__class = Filepath
        setmetatable(F, mt)
        return F
    end
end

return Filepath
--[[
return {
    new = new,
	open = open,
	close = close,
	delete = delete,
    --add = add,
}
--]]
