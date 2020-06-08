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
local Excludes = require("portmaster.excludes")
local Options = require("portmaster.options")
local Msg = require("portmaster.msg")
local Distfile = require("portmaster.distfiles")
local Exec = require("portmaster.exec")

-------------------------------------------------------------------------------------
local P_US = require("posix.unistd")
local access = P_US.access
local sleep = P_US.sleep

-------------------------------------------------------------------------------------
-- return port name without flavor
local function port(origin)
    return (string.match(origin.name, "^[^:@%%]+"))
end

-- return full path to the port directory
local function path(origin)
    return path_concat(PATH.portsdir, port(origin))
end

--
local function check_port_exists(origin)
    return access(path(origin) .. "/Makefile", "r")
end

-- return flavor of passed origin or nil
local function flavor(origin)
    return (string.match(origin.name, "%S+@([^:%%]+)"))
end

--
-- return flavor of passed origin or nil
local function pseudo_flavor(origin)
    return (string.match(origin.name, "%S+%%([^:%%]+)"))
end

-- return path to the portdb directory (contains cached port options)
local function portdb_path(origin)
    local dir = port(origin)
    return PATH.port_dbdir .. dir:gsub("/", "_")
end

-- call make for origin with arguments used e.g. for variable queries (no state change)
local function port_make(origin, args)
    if origin then
        local dir = path(origin)
        local flv = flavor(origin)
        if flv then
            table.insert(args, 1, "FLAVOR=" .. flv)
        end
        --[[
        -- only valid for port_var, not generic port_make !!!
        if args.jailed and PARAM.jailbase then
            dir = PARAM.jailbase .. dir
            args.jailed = false
        end
        --]]
        if not is_dir(dir) then
            return nil, "port directory " .. dir .. " does not exist"
        end
        table.insert(args, 1, "-C")
        table.insert(args, 2, dir)
        local pf = pseudo_flavor(origin)
        if pf then
            table.insert(args, 1, "DEFAULT_VERSIONS='" .. pf .. "'")
            TRACE("DEFAULT_VERSIONS", pf)
        end
    else
        table.insert(args, 1, "-f/usr/share/mk/bsd.port.mk")
    end
    if Options.make_args then
        for i, v in ipairs(Options.make_args) do
            table.insert(args, i, v)
        end
    end
    return Exec.make(args)
end

-- return Makefile variables for port (with optional flavor)
local function port_var(origin, vars)
    local args = {safe = true, table = vars.table}
    for i = 1, #vars do
        args[i] = "-V" .. vars[i]
    end
    if args.trace then
        local dbginfo = debug.getinfo(2, "ln")
        table.insert(args, "LOC=" .. dbginfo.name .. ":" .. dbginfo.currentline)
    end
    table.insert(args, "-DBUILD_ALL_PYTHON_FLAVORS") -- required for make -V FLAVORS to get the full list :X
    local result = port_make(origin, args)
    if result and args.table then
        for i = 1, #vars do
            local value = result[i]
            result[vars[i]] = value ~= "" and value or false
        end
    end
    return result
end

-- local function only to be called when the flavor is queried via __index !!!
local function port_flavor_get(origin)
    local f = flavor(origin)
    if f then
        return f -- return flavor passed in as part of the origin
    end
    --[[
   local flavors = origin.flavors
   if flavors then
      f = flavors[1]
      origin.name = origin.name .. "@" .. f -- adjust origin by appending default flavor to name
   end
   return f
   --]]
end

-- optionally or forcefully configure port
local function configure(origin, force)
    local target = force and "config" or "config-conditional"
    return origin:port_make{to_tty = true, as_root = PARAM.port_dbdir_ro, "-D", "NO_DEPENDS", "-D", "DISABLE_CONFLICTS", target}
end

--[[
-- # wait for a line stating success or failure fetching all distfiles for some port origin and return status
local function wait_checksum(origin)
    if Options.dry_run then
        return true
    end
    local errmsg = "cannot find fetch acknowledgement file"
    local dir = origin.port
    if TMPFILE_FETCH_ACK then
        local status = Exec.run {safe = true, CMD.grep, "-m", "1", "OK " .. dir .. " ", TMPFILE_FETCH_ACK}
        print("'" .. status .. "'")
        if not status then
            sleep(1)
            repeat
                Msg.show {"Waiting for download of all distfiles for", dir, "to complete"}
                status = Exec.run {safe = true, CMD.grep, "-m", "1", "OK " .. dir .. " ", TMPFILE_FETCH_ACK}
                if not status then
                    sleep(3)
                end
            until status
        end
        errmsg = string.match(status, "NOTOK " .. dir .. "(.*)")
        if not errmsg then
            return true
        end
    end
    return false, "Download of distfiles for " .. origin.name .. " failed: " .. errmsg
end
--]]

-- check wether port is on the excludes list
local function check_excluded(origin)
    return Excludes.check_port(origin)
end

-- install newly built port
local function install(origin)
    return origin:port_make{to_tty = true, jailed = true, as_root = true, "install"}
end

--
local function check_license(origin)
    return true -- DUMMY return value XXX
end

-- -------------------------
local MOVED_CACHE = nil -- table indexed by old origin (as text) and giving struct with new origin (as text), date and reason for move
local MOVED_CACHE_REV = nil -- table indexed by new origin (as text) giving previous origin (as text)

--
--[[
Cases:
   1) no flavor -> no flavor (non-flavored port)
   2) no flavor -> with flavor (flavors added)
   3) with flavor -> no flavor (flavors removed)
   4) no flavor -> no flavor (flavored port !!!)

Cases 1, 2 and 3 can easily be dealt with by comparing the
full origin with column 1 (table lookup using full origin).

Case 4 cannot be assumed from the origin having or not having
a flavor - and it looks identical to case 1 in the MOVED file.

If the passed in origin contains a flavor, then entries before
the addition of flavors should be ignored, but there is no way
to reliably get the date when flavors were added from the MOVED
file.
--]]

local function moved_cache_load()
    local function register_moved(old, new, date, reason)
        if old then
            local o_p, o_f = string.match(old, "([^@]+)@?([%S]*)")
            local n_p, n_f = string.match(new, "([^@]+)@?([%S]*)")
            o_f = o_f ~= "" and o_f or nil
            n_f = n_f ~= "" and n_f or nil
            if not MOVED_CACHE[o_p] then
                MOVED_CACHE[o_p] = {}
            end
            table.insert(MOVED_CACHE[o_p], {o_p, o_f, n_p, n_f, date, reason})
            if n_p then
                if not MOVED_CACHE_REV[n_p] then
                    MOVED_CACHE_REV[n_p] = {}
                end
                table.insert(MOVED_CACHE_REV[n_p], {o_p, o_f, n_p, n_f, date, reason})
            end
        end
    end

    if not MOVED_CACHE then
        MOVED_CACHE = {}
        MOVED_CACHE_REV = {}
        local filename = PATH.portsdir .. "MOVED" -- allow override with configuration parameter ???
        Msg.show {level = 2, start = true, "Load list of renamed or removed ports from", filename}
        local movedfile = io.open(filename, "r")
        if movedfile then
            for line in movedfile:lines() do
                register_moved(string.match(line, "^([^#][^|]+)|([^|]*)|([^|]+)|([^|]+)"))
            end
            io.close(movedfile)
        end
        Msg.show {level = 2, "The list of renamed of removed ports has been loaded"}
        Msg.show {level = 2, start = true}
    end
end

-- try to find origin in list of moved or deleted ports, returns new origin or nil if found, false if not found, followed by reason text
local function lookup_moved_origin(origin)
    local function o(p, f)
        if p and f then
            p = p .. "@" .. f
        end
        return p
    end
    local function locate_move(p, f, min_i)
        local m = MOVED_CACHE[p]
        if not m then
            return p, f, nil
        end
        local max_i = #m
        local i = max_i
        TRACE("MOVED?", o(p, f), p, f)
        repeat
            local o_p, o_f, n_p, n_f, date, reason = table.unpack(m[i])
            if p == o_p and (not f or not o_f or f == o_f) then
                local p = n_p
                local f = f ~= o_f and f or n_f
                local r = reason .. " on " .. date
                TRACE("MOVED->", o(p, f), r)
                if not p or access(PATH.portsdir .. p .. "/Makefile", "r") then
                    return p, f, r
                end
                return locate_move(p, f, i + 1)
            end
            i = i - 1
        until i < min_i
        return p, f, nil
    end

    if not MOVED_CACHE then
        moved_cache_load()
    end
    local p, f, r = locate_move(origin.port, origin.flavor, 1)
    if r then
        if p then
            origin = Origin:new(o(p, f))
        end
        origin.reason = r -- XXX reason might be set on wrong port (old vs. new???)
        return origin
    end
end

--
local function check_config_allow(origin, recursive)
    TRACE("CHECK_CONFIG_ALLOW", origin.name, recursive)
    local function check_ignore(name, field)
        TRACE("CHECK_IGNORE", origin.name, name, field, rawget(origin, field))
        if rawget(origin, field) then
            Msg.show {origin.name, "will be skipped since it is marked", name .. ":", origin[field]}
            Msg.show {"If you are sure you can build this port, remove the", name, "line in the Makefile and try again"}
            if not Options.no_confirm then
                Msg.read_nl("Press the [Enter] or [Return] key to continue ")
            end
            origin.skip = true
            return true
        end
    end
    if check_ignore("BROKEN", "is_broken") or check_ignore("IGNORE", "is_ignore") or Options.no_make_config and
        check_ignore("FORBIDDEN", "is_forbidden") then
        return false
    end
    if not recursive then
        local do_config
        if origin.is_forbidden then
            Msg.show {origin.name, "is marked FORBIDDEN:", origin.is_forbidden}
            if origin.all_options then
                Msg.show {"You may try to change the port options to allow this port to build"}
                Msg.show {}
                if Msg.read_yn("Do you want to try again with changed port options") then
                    do_config = true
                end
            end
        elseif origin.new_options or Options.force_config then
            do_config = true
        elseif origin.port_options and origin.options_file and not access(origin.options_file, "r") then
            TRACE("NO_OPTIONS_FILE", origin.options_file)
            -- do_config = true
        end
        if do_config then
            TRACE("NEW_OPTIONS", origin.new_options)
            configure(origin, recursive)
            return false
        end
    end
    -- ask for confirmation if requested by a program option
    if Options.interactive then
        if not Msg.read_yn("Perform upgrade", "y") then
            Msg.show {"Action will be skipped on user request"}
            origin.skip = true
            return false
        end
    end
    -- warn if port is interactive
    if origin.is_interactive then
        Msg.show {"Warning:", origin.name, "is interactive, and will likely require attention during the build"}
        if not Options.no_confirm then
            Msg.read_nl("Press the [Enter] or [Return] key to continue ")
        end
    end
end

-------------------------------------------------------------------------------------
-- create new Origins object or return existing one for given name
-- the Origin class describes a port with optional flavor
local ORIGINS_CACHE = {}
-- setmetatable (ORIGINS_CACHE, {__mode = "v"})

local function __newindex(origin, n, v)
    TRACE("SET(o)", origin.name, n, v)
    rawset(origin, n, v)
end

--
local ORIGIN_ALIAS = {}

--
local function get(name)
    if name then
        local result = rawget(ORIGINS_CACHE, name)
        if result == false then
            return get(ORIGIN_ALIAS[name])
        end
        TRACE("GET(o)->", name, result)
        return result
    end
end

--
local function delete(origin)
    ORIGINS_CACHE[origin.name] = nil
end

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache()
    local t = ORIGINS_CACHE
    for i, v in ipairs(table.keys(t)) do
        if t[v] then
            TRACE("ORIGINS_CACHE", i, v, t[v])
        else
            TRACE("ORIGINS_CACHE", i, v, "ALIAS", ORIGIN_ALIAS[v])
        end
    end
    local t = ORIGIN_ALIAS
    for i, v in ipairs(table.keys(t)) do
        TRACE("ORIGIN_ALIAS", i, v, t[v])
    end
end

-------------------------------------------------------------------------------------
local __port_vars_table = {
    table = true,
    "PKGNAME",
    "FLAVOR",
    "FLAVORS",
    "DISTINFO_FILE",
    "BROKEN",
    "FORBIDDEN",
    "IGNORE",
    "IS_INTERACTIVE",
    "NO_BUILD",
    "MAKE_JOBS_UNSAFE",
    "LICENSE",
    "ALL_OPTIONS",
    "NEW_OPTIONS",
    "PORT_OPTIONS",
    "CATEGORIES",
    "FETCH_DEPENDS",
    "EXTRACT_DEPENDS",
    "PATCH_DEPENDS",
    "BUILD_DEPENDS",
    "LIB_DEPENDS",
    "RUN_DEPENDS",
    "TEST_DEPENDS",
    "PKG_DEPENDS",
    "CONFLICTS_BUILD",
    "CONFLICTS_INSTALL",
    "CONFLICTS",
    "DISTFILES", -- may have ":" followed by fetch label appended
    "PATCHFILES", -- as above
    "DIST_SUBDIR",
    "OPTIONS_FILE",
}

local function __port_vars(origin, k, recursive)
    local function check_origin_alias(origin)
        local function adjustname(origin, new_name)
            TRACE("ORIGIN_SETALIAS", origin.name, new_name)
            ORIGIN_ALIAS[origin.name] = new_name
            local o = Origin.get(new_name)
            if o then -- origin with alias has already been seen, move fields over and continue with new table
                o.flavors = rawget(origin, "flavors")
                o.pkg_new = rawget(origin, "pkg_new")
                origin = o
            end
            ORIGINS_CACHE[origin.name] = false -- poison old value to cause error if accessed
            origin.name = new_name
            ORIGINS_CACHE[new_name] = origin
        end
        -- add missing default flavor, if applicable
        local default_flavor = origin.flavors and origin.flavors[1]
        local name = origin.name
        if default_flavor and not string.match(name, "@") then -- flavor and default_version do not mix !!! check required ???
            adjustname(origin, name .. "@" .. default_flavor)
        end
        -- check for existing package cache entry and its origin
        local p = origin.pkg_new
        local o = p and p.origin -- MERGE !!!
        TRACE("CHECK_ORIGIN_ALIAS", origin and origin.name or "<nil>", o and o.name or "<nil>", p and p.name or "<nil>")
        if o and o.name ~= origin.name then
            adjustname(origin, o.name)
        end
    end
    local function set_pkgname(origin, var, pkgname)
        if pkgname then
            local p = Package:new(pkgname)
            TRACE("PKG_NEW", pkgname, origin.name, p.origin and p.origin.name or "''")
            origin[var] = p
        end
    end
    local t = origin:port_var(__port_vars_table)
    TRACE("PORT_VAR(" .. origin.name .. ", " .. k .. ")", table.unpack(t))
    if t then
        -- first check for and update port options since they might affect the package name
        set_table(origin, "new_options", t.NEW_OPTONS)
        origin.is_broken = t.BROKEN
        origin.is_forbidden = t.FORBIDDEN
        origin.is_ignore = t.IGNORE
        set_pkgname(origin, "pkg_new", t.PKGNAME)
        origin.flavor = t.FLAVOR
        set_table(origin, "flavors", t.FLAVORS)
        check_origin_alias(origin) ---- SEARCH FOR AND MERGE WITH POTENTIAL ALIAS
        origin.distinfo_file = t.DISTINFO_FILE
        set_bool(origin, "is_interactive", t.IS_INTERACTIVE)
        set_bool(origin, "no_build", t.NO_BUILD)
        set_bool(origin, "make_jobs_unsafe", t.MAKE_JOBS_UNSAFE)
        set_table(origin, "license", t.LICENSE)
        set_table(origin, "all_options", t.ALL_OPTIONS)
        set_table(origin, "new_options", t.NEW_OPTIONS)
        set_table(origin, "port_options", t.PORT_OPTIONS)
        set_table(origin, "categories", t.CATEGORIES)
        set_table(origin, "fetch_depends_var", t.FETCH_DEPENDS)
        set_table(origin, "extract_depends_var", t.EXTRACT_DEPENDS)
        set_table(origin, "patch_depends_var", t.PATCH_DEPENDS)
        set_table(origin, "build_depends_var", t.BUILD_DEPENDS)
        set_table(origin, "lib_depends_var", t.LIB_DEPENDS)
        set_table(origin, "run_depends_var", t.RUN_DEPENDS)
        set_table(origin, "test_depends_var", t.TEST_DEPENDS)
        set_table(origin, "pkg_depends_var", t.PKG_DEPENDS)
        set_table(origin, "conflicts_build_var", t.CONFLICTS_BUILD)
        set_table(origin, "conflicts_install_var", t.CONFLICTS_INSTALL)
        set_table(origin, "conflicts_var", t.CONFLICTS)
        set_table(origin, "distfiles", t.DISTFILES)
        set_table(origin, "patchfiles", t.PATCHFILES)
        origin.dist_subdir = t.DIST_SUBDIR
        origin.options_file = t.OPTIONS_FILE
    end
    return rawget(origin, k)
end

--
local function __port_depends(origin, k)
    local depends_table = {
        build_depends = {
            "extract_depends_var", "patch_depends_var", "fetch_depends_var", "build_depends_var", "lib_depends_var",
            "pkg_depends_var",
        },
        run_depends = {"lib_depends_var", "run_depends_var"},
        test_depends = {"test_depends_var"},
        special_depends = {"build_depends_var"},
    }
    local t = depends_table[k]
    assert(t, "non-existing dependency " .. k or "<nil>" .. " requested")
    local ut = {}
    for _, v in ipairs(t) do
        for _, d in ipairs(origin[v] or {}) do
            local pattern = k == "special_depends" and "^[^:]+:([^:]+:%S+)" or "^[^:]+:([^:]+)$"
            TRACE("PORT_DEPENDS", k, d, pattern)
            local o = string.match(d, pattern)
            if o then
                ut[o] = true
            end
        end
    end
    return table.keys(ut)
end

--
local function __port_conflicts(origin, k)
    local conflicts_table = {
        build_conflicts = {"conflicts_build_var", "conflicts_var"},
        install_conflicts = {"conflicts_install_var", "conflicts_var"},
    }
    local t = conflicts_table[k]
    assert(t, "non-existing conflict type " .. k or "<nil>" .. " requested")
    local ut = {}
    for _, v in ipairs(t) do
        local t = origin[v]
        TRACE("CHECK_C?", origin.name, k, v)
        if t then
            for _, d in ipairs(t) do
                ut[d] = true
            end
        end
    end
    return table.keys(ut)
end

-------------------------------------------------------------------------------------
--
local __index_dispatch = {
    distinfo_file = __port_vars,
    is_broken = __port_vars,
    is_forbidden = __port_vars,
    is_ignore = __port_vars,
    is_interactive = __port_vars,
    license = __port_vars,
    flavors = __port_vars,
    flavor = port_flavor_get,
    all_options = __port_vars,
    new_options = __port_vars,
    port_options = __port_vars,
    categories = __port_vars,
    options_file = __port_vars,
    -- pkg_old = Package.packages_cache_load,
    pkg_new = __port_vars,
    -- old_pkgs = PkgDb.pkgname_from_origin,
    path = path,
    port = port,
    port_exists = check_port_exists,
    fetch_depends = __port_depends,
    extract_depends = __port_depends,
    patch_depends = __port_depends,
    build_depends = __port_depends,
    run_depends = __port_depends,
    pkg_depends = __port_depends,
    special_depends = __port_depends,
    fetch_depends_var = __port_vars,
    extract_depends_var = __port_vars,
    patch_depends_var = __port_vars,
    build_depends_var = __port_vars,
    lib_depends_var = __port_vars,
    pkg_depends_var = __port_vars,
    run_depends_var = __port_vars,
    test_depends_var = __port_vars,
    conflicts_build_var = __port_vars,
    conflicts_install_var = __port_vars,
    conflicts_var = __port_vars,
    build_conflicts = __port_conflicts,
    install_conflicts = __port_conflicts,
}

local function __index(origin, k)
    TRACE("INDEX(o)", origin, k)
    local w = rawget(origin.__class, k)
    if w == nil then
        rawset(origin, k, false)
        local f = __index_dispatch[k]
        if f then
            w = f(origin, k)
            if w then
                rawset(origin, k, w)
            else
                w = false
            end
        else
            error("illegal field requested: Origin." .. k)
        end
        TRACE("INDEX(o)->", origin, k, w)
    else
        TRACE("INDEX(o)->", origin, k, w, "(cached)")
    end
    return w
end

-------------------------------------------------------------------------------------
--
local mt = {
    __index = __index,
    __newindex = __newindex, -- DEBUGGING ONLY
    __tostring = function(self)
        return self.name
    end,
}

--
local function new(Origin, name)
    if name then
        local O = get(name)
        if not O then
            O = {name = name}
            O.__class = Origin
            setmetatable(O, mt)
            TRACE("NEW Origin", name)
            ORIGINS_CACHE[name] = O
        else
            TRACE("NEW Origin", name, "(cached)", O.name)
        end
        return O
    end
    return nil
end

-------------------------------------------------------------------------------------
--
return {
    -- name = false,
    new = new,
    get = get,
    check_excluded = check_excluded,
    check_config_allow = check_config_allow,
    fetch = Distfile.fetch,
    fetch_wait = Distfile.fetch_wait,
    delete = delete,
    install = install,
    port_make = port_make,
    port_var = port_var,
    portdb_path = portdb_path,
    --wait_checksum = wait_checksum,
    moved_cache_load = moved_cache_load,
    lookup_moved_origin = lookup_moved_origin,
    dump_cache = dump_cache,
    check_license = check_license,
}
