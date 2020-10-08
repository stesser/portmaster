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
local Exec = require("portmaster.exec")
local Lock = require("portmaster.lock")
local PkgDbLock

-------------------------------------------------------------------------------------
local function lock(shared)
    PkgDbLock = PkgDbLock or Lock.new("PkgDbLock")
    PkgDbLock:acquire{weight = 1, shared = shared}
end

local function unlock(shared)
    PkgDbLock:release{weight = 1, shared = shared}
end

local function pkg(args)
    local shared = args.safe
    lock(shared)
    local result = Exec.pkg(args)
    unlock(shared)
    return result
end

-------------------------------------------------------------------------------------
-- query package DB for passed origin (with optional flavor) or passed package name
-- <se> actually not working for origin with flavor due to lack of transparent support in "pkg"
local function query(args)
    if args.cond then
        table.insert(args, 1, "-e")
        table.insert(args, 2, args.cond)
    end
    if args.pkgfile then
        table.insert(args, 1, "-F")
        table.insert(args, 2, args.pkgfile)
    end
    if args.glob then
        table.insert(args, 1, "-g")
    end
    table.insert(args, 1, "query")
    args.safe = true
    return pkg(args)
end

-- get package information from pkgdb
local function info(...)
    return pkg{
        safe = true,
        table = true,
        "info", "-q", ...
    }
end

-- set package attribute for specified ports and/or packages
local function set(...)
    return pkg{
        as_root = true,
        log = true,
        "set", "-y", ...
    }
end

-- get the annotation value (e.g. flavor), if any
local function annotate_get(var, name)
    assert(var, "no var passed")
    return pkg{
        safe = true,
        "annotate", "-Sq", name, var
    }
end

-- set the annotation value, or delete it if "$value" is empty
local function annotate_set(var, name, value)
    local opt = value and #value > 0 and "-M" or "-D"
    return pkg{
        as_root = true,
        log = true,
        "annotate", "-qy", opt, name, var, value
    }
end

-- check package dependency information in the pkg db
local function check_depends()
    pkg{
        as_root = true,
        to_tty = true,
        "check", "-dn"
    }
end

-- return system ABI
local function system_abi()
    local abi = chomp(pkg{
        safe = true,
        "config", "abi"
    })
    local abi_noarch = string.match(abi, "^[%a]+:[%d]+:") .. "*"
    TRACE("SYSTEM_ABI", abi, abi_noarch)
    return abi, abi_noarch
end

-- ---------------------------------------------------------------------------
-- lookup flavor of given package in the package database
local function flavor_get(pkgname)
    local result = annotate_get("flavor", pkgname)
    if result ~= "" then
        return result
    end
end

-- set flavor of given package in the package database
local function flavor_set(pkgname, flavor)
    annotate_set("flavor", pkgname, flavor)
end

-- check flavor of given package in the package database
local function flavor_check(pkgname, flavor)
    return flavor_get(pkgname) == flavor
end

-- register new origin in package registry (must be performed before package rename, if any)
local function update_origin(old, new, pkgname)
    local dir_old = old.port
    local dir_new = new.port
    local flavor = new.flavor

    if dir_old ~= dir_new then
        if not set("--change-origin", dir_old .. ":" .. dir_new, pkgname) then
            return false, "Could not change origin of " .. tostring(pkgname) .. " from " .. dir_old .. " to " .. dir_new
        end
    end
    if not flavor_check(pkgname, flavor) then
        if not flavor_set(pkgname, flavor) then
            return false, "Could not set flavor of " .. tostring(pkgname) .. " to " .. flavor
        end
    end
    return true
end

local function update_pkgname(p_o, p_n)
    if not set("--change-name", p_o.name_base .. ":" .. p_n.name_base, p_o.name) then
        return false, "Could not change package name of " .. p_o.name ..  " to " .. p_n.name
    end
    return true
end

-- update repository database after creation of new packages
local function update_repo() -- move to Package module XXX
    pkg {
        as_root = true,
        "repo", PATH.packages .. "All"
    }
end

return {
    query = query,
    info = info,
    set = set,
    check_depends = check_depends,
    system_abi = system_abi,
    flavor_get = flavor_get,
    flavor_set = flavor_set,
    flavor_check = flavor_check,
    update_origin = update_origin,
    update_pkgname = update_pkgname,
    update_repo = update_repo,
    lock = lock,
    unlock = unlock,
}
