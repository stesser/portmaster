--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019-2021 Stefan Eßer <se@freebsd.org>

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
local Distfile = require("portmaster.distfiles")
local Exec = require("portmaster.exec")
local Param = require("portmaster.param")
local Trace = require("portmaster.trace")
local Util = require("portmaster.util")

-------------------------------------------------------------------------------------
local P_US = require("posix.unistd")
local access = P_US.access
local TRACE = Trace.trace

-------------------------------------------------------------------------------------
-- return port name without flavor
local function port(origin)
    return (string.match(origin.name, "^[^:@%%]+"))
end

-- return full path to the port directory
local function path(origin)
    return Param.portsdir + port(origin)
end

--
local function check_port_exists(origin)
    return (path(origin) + "Makefile").is_readable
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
    --TRACE("PORTDB_PATH", origin.name, dir, path_concat(Param.port_dbdir, dir:gsub("/", "_")))
    return Param.port_dbdir + dir:gsub("/", "_")
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
        if args.jailed and Param.jailbase then
            dir = Param.jailbase .. dir
            args.jailed = false
        end
        --]]
        if not dir.is_dir then
            return "", "port directory " .. dir.name .. " does not exist", 20 -- ENOTDIR
        end
        table.insert(args, 1, "-C")
        table.insert(args, 2, dir.name)
        local pf = pseudo_flavor(origin)
        if pf then
            args.env = args.env or {}
            args.env.DEFAULT_VERSIONS = pf
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
local function port_var(o_n, vars)
    local args = {safe = true, table = vars.table}
    for i = 1, #vars do
        args[i] = "-V" .. vars[i]
    end
    if args.trace then
        local dbginfo = debug.getinfo(2, "ln")
        table.insert(args, "LOC=" .. dbginfo.name .. ":" .. dbginfo.currentline)
    end
    table.insert(args, "-DBUILD_ALL_PYTHON_FLAVORS") -- required for make -V FLAVORS to get the full list :X
    local out, _, exitcode = port_make(o_n, args)
    --TRACE("PORTVAR->", out, exitcode)
    if exitcode ~= 0 then
        out = nil
    end
    if out and args.table then
        for i = 1, #vars do
            local value = out[i]
            out[vars[i]] = value ~= "" and value or false
        end
    end
    return out
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
local function install(o_n)
    return o_n:port_make{
        log = true,
        jailed = true,
        as_root = true,
        pkgdb_wr = true,
        "install"
    }
end

--
local function check_license(o_n)
    return true -- DUMMY return value XXX
end

-------------------------------------------------------------------------------------
-- create new Origins object or return existing one for given name
-- the Origin class describes a port with optional flavor
local ORIGINS_CACHE = {}
-- setmetatable (ORIGINS_CACHE, {__mode = "v"})

local function __newindex(origin, n, v)
    --TRACE("SET(o)", origin.name, n, v)
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
        --TRACE("GET(o)->", name, result)
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
    for i, v in ipairs(Util.table_keys(t)) do
        if t[v] then
            TRACE("ORIGINS_CACHE", i, v, t[v])
        else
            TRACE("ORIGINS_CACHE", i, v, "ALIAS", ORIGIN_ALIAS[v])
        end
    end
    t = ORIGIN_ALIAS
    for i, v in ipairs(Util.table_keys(t)) do
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
    "MAKE_JOBS_NUMBER",
    "MAKE_JOBS_NUMBER_LIMIT",
    "MAKE_JOBS_UNSAFE",
    "DISABLE_MAKE_JOBS",
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
    "WRKDIR",
    "DEPRECATED",
    "EXPIRATION_DATE",
}

local function __port_vars(origin, k, recursive)
    local function check_origin_alias(origin)
        local function adjustname(origin, new_name)
            --TRACE("ORIGIN_SETALIAS", origin.name, new_name)
            ORIGIN_ALIAS[origin.name] = new_name
            local o = get(new_name)
            if o then -- origin with alias has already been seen, move fields over and continue with new table
                o.flavors = rawget(origin, "flavors")
                o.pkgname = rawget(origin, "pkgname") -- XXX required ???
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
    end
    local function set_table(self, field, v)
        self[field] = v ~= "" and Util.split_words(v) or false
    end
    local function set_bool(self, field, v)
        self[field] = (v and v ~= "" and v ~= "0") and true or false
    end
    local t = origin:port_var(__port_vars_table)
    --TRACE("PORT_VAR(" .. origin.name .. ", " .. k .. ")", t)
    if t then
        -- first check for and update port options since they might affect the package name
        set_table(origin, "new_options", t.NEW_OPTONS)
        origin.is_broken = t.BROKEN
        origin.is_forbidden = t.FORBIDDEN
        origin.is_ignore = t.IGNORE
        --set_pkgname(origin, "pkg_new", t.PKGNAME)
        origin.pkgname = t.PKGNAME
        origin.flavor = t.FLAVOR
        set_table(origin, "flavors", t.FLAVORS)
        check_origin_alias(origin) ---- SEARCH FOR AND MERGE WITH POTENTIAL ALIAS
        origin.distinfo_file = t.DISTINFO_FILE
        set_bool(origin, "is_interactive", t.IS_INTERACTIVE)
        set_bool(origin, "no_build", t.NO_BUILD)
        origin.make_jobs_number = tonumber(t.MAKE_JOBS_NUMBER)
        origin.make_jobs_number_limit = tonumber(t.MAKE_JOBS_NUMBER_LIMIT) or origin.make_jobs_number
        set_bool(origin, "make_jobs_unsafe", t.MAKE_JOBS_UNSAFE)
        set_bool(origin, "disable_make_jobs", t.DISABLE_MAKE_JOBS)
        set_table(origin, "license", t.LICENSE)
        set_table(origin, "all_options", t.ALL_OPTIONS)
        set_table(origin, "new_options", t.NEW_OPTIONS)
        set_table(origin, "port_options", t.PORT_OPTIONS)
        set_table(origin, "categories", t.CATEGORIES)
        origin.depend_var = {}
        set_table(origin.depend_var, "fetch", t.FETCH_DEPENDS)
        set_table(origin.depend_var, "extract", t.EXTRACT_DEPENDS)
        set_table(origin.depend_var, "patch", t.PATCH_DEPENDS)
        set_table(origin.depend_var, "build", t.BUILD_DEPENDS)
        set_table(origin.depend_var, "lib", t.LIB_DEPENDS)
        set_table(origin.depend_var, "run", t.RUN_DEPENDS)
        set_table(origin.depend_var, "test", t.TEST_DEPENDS)
        set_table(origin.depend_var, "pkg", t.PKG_DEPENDS)
        set_table(origin, "conflicts_build_var", t.CONFLICTS_BUILD)
        set_table(origin, "conflicts_install_var", t.CONFLICTS_INSTALL)
        set_table(origin, "conflicts_var", t.CONFLICTS)
        set_table(origin, "distfiles", t.DISTFILES)
        set_table(origin, "patchfiles", t.PATCHFILES)
        origin.dist_subdir = t.DIST_SUBDIR
        origin.options_file = t.OPTIONS_FILE
        origin.wrkdir = t.WRKDIR
        origin.deprecated = t.DEPRECATED
        origin.expiration_date = t.EXPIRATION_DATE
        if  origin.expiration_date then
            local year, month, day = string.match(origin.expiration_date, "(%d+)-(%d+)-(%d+)")
            -- calculate UNIX time of end of expiration time (midnight UTC of last day)
            origin.expiration_secs = os.time{year=year, month = month, day=day, hour = 0, minute = 0} + 24 * 3600
        end
    end
    return rawget(origin, k)
end

--
local function __port_conflicts(origin, k)
    local conflicts_table = {
        build_conflicts = {"conflicts_build_var", "conflicts_var"},
        install_conflicts = {"conflicts_install_var", "conflicts_var"},
    }
    local t = conflicts_table[k]
    assert(t, "non-existing conflict type " .. k or "<nil>" .. " requested")
    local seen = {}
    local result = {}
    for _, v in ipairs(t) do
        local conflicts = origin[v]
        --TRACE("CHECK_C?", origin.name, k, v)
        if conflicts then
            for _, d in ipairs(conflicts) do
                if not seen[d] then
                    result[#result+1] = d
                    seen[d] = true
                end
            end
        end
    end
    return result
end

-- strip any implicit default flavor -- XXX and strip pseudo-flavor too ???
local function __short_name(origin)
    local f = origin.flavor
    if f then
        local ff = origin.flavors
        if ff and f == ff[1] then
            return origin.port
        end
    end
    return origin.name
end

--
local function __verify_origin(o)
    if o and o.name and o.name ~= "" then
        return (o.path + "Makefile").is_readable
    end
end

--
local function __special_depends(o)
    local result = {}
    local build_depends = o.depend_var.build
    if build_depends then
        for _, entry in ipairs(build_depends) do
            TRACE("__SPECIAL_DEPEND?", entry)
            local origin_target = string.match(entry, "^[^:]+:([^:]+:%a+)")
            if origin_target then
                result[#result + 1] = origin_target
                TRACE("__SPECIAL_DEPEND->", origin_target)
            end
        end
    end
    return result
end

--
local function __depends(origin, k)
    local depends_table = {
        build = {
            "extract",
            "patch",
            "build",
            "lib"
        },
        fetch = {
            "fetch"
        },
        pkg = {
            "pkg"
        },
        run = {
            "lib",
            "run"
        },
        test = {
            "test"
        },
        special = {
            "build"
        },
    }
    local depends = {}
    if origin.depend_var then
        for type, table in pairs(depends_table) do
            local depends_tmp = {}
            for _, depvar_name in ipairs(table) do
                local depvar = origin.depend_var[depvar_name]
                if depvar then
                    for _, depdef in ipairs(depvar) do
                        local pattern = type == "special" and "^([^:]+):([^:]+:%S+)" or "^([^:]+):([^:]+)$"
                        local test, dep_origin = string.match(depdef, pattern)
                        TRACE("PORT_DEPENDS", type, depdef, pattern, test, dep_origin)
                        if dep_origin then
                            depends_tmp[dep_origin] = test
                        end
                    end
                end
            end
            if next(depends_tmp) then
                depends[type] = depends_tmp
            end
        end
    end
    return depends
end

-------------------------------------------------------------------------------------
--
local __index_dispatch = {
    distinfo_file = __port_vars,
    is_broken = __port_vars,
    is_forbidden = __port_vars,
    is_ignore = __port_vars,
    is_interactive = __port_vars,
    make_jobs_number = __port_vars,
    make_jobs_number_limit = __port_vars,
    license = __port_vars,
    flavors = __port_vars,
    flavor = port_flavor_get,
    all_options = __port_vars,
    new_options = __port_vars,
    port_options = __port_vars,
    categories = __port_vars,
    options_file = __port_vars,
    pkgname = __port_vars,
    distfiles = __port_vars,
    depend_var = __port_vars,
    depends = __depends,
    special_depends = __special_depends,
    conflicts_build_var = __port_vars,
    conflicts_install_var = __port_vars,
    conflicts_var = __port_vars,
    wrkdir = __port_vars,
    path = path,
    port = port,
    port_exists = check_port_exists,
    build_conflicts = __port_conflicts,
    install_conflicts = __port_conflicts,
    short_name = __short_name,
    exists = __verify_origin,
    old_pkgs = function ()
        return {"NIL"}
    end
}

local function __index(origin, k)
    --TRACE("INDEX(o)", origin, k)
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
        --TRACE("INDEX(o)->", origin, k, w)
    else
        --TRACE("INDEX(o)->", origin, k, w, "(cached)")
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
            --TRACE("NEW Origin", name)
            ORIGINS_CACHE[name] = O
        else
            --TRACE("NEW Origin", name, "(cached)", O.name)
        end
        return O
    end
    return nil
end

local function getmultiple(Origin, origins)
    local function __pkgname(o_n)
        return o_n.pkgname -- dummy fetch to force loading of port variables
    end
    TRACE("GETMULTIPLE", origins)
    for n, name in ipairs(origins) do
        if name then
            TRACE("GETMULTIPLE:", n, name)
            local o_n = new(Origin, name )
            if not rawget(o_n, "pkgname") then
                Exec.spawn(__pkgname, o_n)
            end
        else
            TRACE("GETMULTIPLE?", origins)
        end
    end
    Exec.finish_spawned(__pkgname)
    local result = {}
    for _, name in ipairs(origins) do
        result[#result + 1] = get(name)
    end
    TRACE("GETMULTIPLE->", result)
    return result
end

--
local function make_index(Origin)
    local function get_subdirs(dir)
        return Util.split_words(Exec.make{"-C", dir, "-V", "SUBDIR"})
    end
    local port = {}
    local categories = get_subdirs("/usr/ports")
    for _, category in ipairs(categories) do
        port[category] = get_subdirs("/usr/ports/" .. category)
    end
    local all_ports = {}
    for category, ports in pairs(port) do
        for _, p in ipairs(ports) do
            all_ports[#all_ports + 1] = category .. "/" .. p
        end
    end
    --TRACE("ALL_PORTS", all_ports)
    getmultiple(Origin, all_ports)
end

-------------------------------------------------------------------------------------
--
return {
    -- name = false,
    new = new,
    get = get,
    getmultiple = getmultiple,
    check_excluded = check_excluded,
    --check_config_allow = check_config_allow,
    fetch = Distfile.fetch,
    fetch_wait = Distfile.fetch_wait,
    delete = delete,
    install = install,
    port_make = port_make,
    port_var = port_var,
    portdb_path = portdb_path,
    dump_cache = dump_cache,
    check_license = check_license,
    make_index = make_index,
}
