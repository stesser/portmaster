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
local Excludes = require("portmaster.excludes")
local Options = require("portmaster.options")
local PkgDb = require("portmaster.pkgdb")
local Msg = require("portmaster.msg")
local Progress = require("portmaster.progress")
local Exec = require("portmaster.exec")

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

-------------------------------------------------------------------------------------
-- the Package class describes a package with optional package file

--
local function filename(args)
    local pkg = args[1]
    local pkgname = pkg.name
    local base = args.base or PATH.packages
    local subdir = args.subdir or "All"
    local extension = args.ext or PARAM.package_format
    if string.sub(extension, 1, 1) ~= "." then
        extension = "." .. extension
    end
    local result = path_concat(base, subdir, pkgname .. extension)
    TRACE("FILENAME->", result, base, subdir, pkgname, extension)
    return result
end

-- fetch ABI from package file
local function file_get_abi(filename)
    return PkgDb.query {pkgfile = filename, "%q"} -- <se> %q vs. %Q ???
end

-- check whether ABI of package file matches current system PARAM.abi
local function file_valid_abi(file)
    local abi = file_get_abi(file)
    return abi == PARAM.abi or abi == PARAM.abi_noarch
end

-- return package version
local function pkg_version(pkg)
    local v = (string.match(pkg.name, ".*-([^-]+)"))
    TRACE("VERSION", pkg.name, v)
    return v
end

-- return package basename without version
local function pkg_basename(pkg)
    return (string.match(pkg.name, "(%S+)-"))
end

-- return package name with only the first part of the version number
local function pkg_strip_minor(pkg)
    local major = string.match(pkg_version(pkg), "([^.]+)%.%S+")
    local result = pkg_basename(pkg) .. "-" .. (major or "")
    TRACE("STRIP_MINOR", pkg.name, result)
    return result
end

-------------------------------------------------------------------------------------
-- remove from shlib backup directory all shared libraries replaced by new versions
-- preserve currently installed shared libraries // <se> check name of control variable
local function shlibs_backup(pkg)
    local pkg_libs = pkg.shared_libs
    if pkg_libs then
        local ldconfig_lines = Exec.run{ -- "RT?" ??? CACHE LDCONFIG OUTPUT???
            table = true,
            safe = true,
            CMD.ldconfig, "-r"
        }
        for _, line in ipairs(ldconfig_lines) do
            local libpath, lib = string.match(line, " => (" .. PATH.local_lib .. "*(lib.*%.so%..*))")
            if lib then
                if stat_isreg(lstat(libpath).st_mode) then
                    for _, l in ipairs(pkg_libs) do
                        if l == lib then
                            local backup_lib = PATH.local_lib_compat .. lib
                            if access(backup_lib, "r") then
                                Exec.run{
                                    as_root = true,
                                    log = true,
                                    CMD.unlink, backup_lib
                                }
                            end
                            Exec.run{
                                as_root = true,
                                log = true,
                                CMD.cp, libpath, backup_lib
                            }
                        end
                    end
                end
            end
        end
    end
end

-- remove from shlib backup directory all shared libraries replaced by new versions
local function shlibs_backup_remove_stale(pkg)
    local pkg_libs = pkg.shared_libs
    if pkg_libs then
        local deletes = {}
        for _, lib in ipairs(pkg_libs) do
            local backup_lib = PATH.local_lib_compat .. lib
            if access(backup_lib, "r") then
                table.insert(deletes, backup_lib)
            end
        end
        if #deletes > 0 then
            Exec.run{
                as_root = true,
                log = true,
                CMD.rm, "-f", table.unpack(deletes)
            }
            Exec.run{
                as_root = true,
                log = true,
                CMD.ldconfig, "-R"
            }
        end
        return true
    end
end

-------------------------------------------------------------------------------------
-- deinstall named package (JAILED)
local function backup_old_package(package)
    local pkgname = package.name
    return Exec.pkg{
        as_root = PARAM.packages_ro,
        "create", "-q", "-o", PATH.packages_backup, "-f", PARAM.backup_format, pkgname
    }
end

--
local function deinstall(package)
    local pkgname = package.name
    local from_jail = Options.jailed and PARAM.phase ~= "install"
    return Exec.pkg{
        log = true,
        jailed = from_jail,
        as_root = not from_jail,
        "delete", "-y", "-q", "-f", pkgname
    }
end

-------------------------------------------------------------------------------------
-- get package message in case of an installation to the base system
local function message(pkg)
    if not Options.dry_run and (not Options.jailed or PARAM.phase == "install") then
        local msg = PkgDb.query {"%M", pkg.name}
        if type(msg) == "string" then
            return msg
        end
    end
end

-------------------------------------------------------------------------------------
-- install package from passed pkg
local function install(pkg, abi)
    local pkgfile = pkg.pkg_filename
    local jailed = Options.jailed and PARAM.phase == "build"
    local env = {IGNORE_OSVERSION = "yes"}
    TRACE("INSTALL", abi, pkgfile)
    if string.match(pkgfile, ".*/pkg-[^/]+$") then -- pkg command itself
        if not access(CMD.pkg, "x") then
            env.ASSUME_ALWAYS_YES = "yes"
            local flag, errmsg = Exec.run{
                as_root = true,
                jailed = jailed, -- ???
                log = true,
                env = env,
                CMD.pkg_b, "-v"
            }
            if not flag then
                return flag, errmsg
            end
        end
        env.SIGNATURE_TYPE = "none"
    elseif abi then
        env.ABI = abi
    end
    return Exec.pkg{
        log = true,
        as_root = true,
        jailed = jailed,
        env = env,
        "add", "-M", pkgfile
    }
end

-- create category links and a lastest link
local function category_links_create(pkg_new, categories)
    local extension = PARAM.package_format
    local source = filename {base = "..", ext = extension, pkg_new}
    table.insert(categories, "Latest")
    for _, category in ipairs(categories) do
        local destination = path_concat (PATH.packages, category)
        if not is_dir(destination) then
            Exec.run{
                as_root = PARAM.packages_ro,
                log = true,
                CMD.mkdir, "-p", destination
            }
        end
        if category == "Latest" then -- skip if/since automatically created???
            destination = path_concat (destination, pkg_new.name_base .. "." .. extension)
        end
        Exec.run{
            as_root = PARAM.packages_ro,
            log = true,
            CMD.ln, "-sf", source, destination
        }
    end
end

--
-- re-install package from backup after attempted installation of a new version failed
local function recover(pkg)
    -- if not pkgname then return true end
    local pkgname = pkg.name
    local pkgfile = pkg.pkgfile
    if not pkgfile then
        pkgfile = Exec.run{
            table = true,
            safe = true,
            CMD.ls, "-1t", filename{base = PATH.packages_backup, subdir = "", ext = ".*", pkg}}[1] -- XXX replace with glob and sort by modification time ==> pkg.bakfile
    end
    if pkgfile and access(pkgfile, "r") then
        Msg.show {"Re-installing previous version", pkgname}
        if install(pkgfile, pkg.pkgfile_abi) then
            if pkg.is_automatic == 1 then
                pkg:automatic_set(true)
            end
            shlibs_backup_remove_stale(pkg)
            --[[ Exec.run{ -- required ???
                as_root = true,
                log = true,
                CMD.unlink, PATH.packages_backup .. pkgname .. ".t??"
            }--]]
            return true
        end
    end
    Msg.show {"Recovery from backup package file", pkgfile, "failed"}
end

-- search package file
local function file_search(pkg)
    for d in ipairs({"All", "package-backup"}) do
        local file
        for _, f in ipairs(glob(filename {subdir = d, ext = ".t??", pkg}) or {}) do
            if file_valid_abi(f) then
                if not file or stat(file).modification < stat(f).modification then
                    file = f
                end
            end
        end
        if file then
            return file
        end
    end
end

-- lookup package file
local function pkg_lookup(pkg, k)
    local subdir = k == "pkgfile" and "All" or "portmaster-backup"
    local file
    for _, f in ipairs(glob(filename {subdir = subdir, ext = ".t??", pkg}) or {}) do
        if file_valid_abi(f) then
            if not file or stat(file).st_mtime < stat(f).st_mtime then
                file = f
            end
        end
    end
    return file
end

-- delete backup package file
local function backup_delete(pkg)
    local g = filename {subdir = "portmaster-backup", ext = ".t??", pkg}
    for _, backupfile in pairs(glob(g) or {}) do
        TRACE("BACKUP_DELETE", backupfile, PATH.packages .. "portmaster-backup/")
        Exec.run{
            as_root = true,
            log = true,
            CMD.unlink, backupfile
        }
    end
end

-- delete stale package file ==> convert to be based on pkg.pkgfile and pkg.bakfile XXX
local function delete_old(pkg)
    local bakfile = pkg.bak_file
    local g = filename {subdir = "*", ext = "t??", pkg}
    TRACE("DELETE_OLD", pkg.name, g)
    for _, pkgfile in pairs(glob(g) or {}) do
        TRACE("CHECK_BACKUP", pkgfile, bakfile)
        if pkgfile ~= bakfile then
            Exec.run{
                as_root = true,
                log = true,
                CMD.unlink, pkgfile
            }
        end
    end
end

-------------------------------------------------------------------------------------
-- return true (exit code 0) if named package is locked
-- set package to auto-installed if automatic == 1, user-installed else
local function automatic_set(pkg, automatic)
    TRACE("AUTOMATIC_SET", pkg, automatic)
    local value = automatic and "1" or "0"
    PkgDb.set("-A", value, pkg.name)
end

-- check whether package is on includes list
local function check_excluded(pkg)
    return Excludes.check_pkg(pkg)
end

-- check package name for possibly used default version parameter
local function check_default_version(origin_name, pkgname)
    local T = {
        apache = "^apache(%d)(%d)-",
        -- llvm= "^llvm(%d%d)-",
        -- lua = "^lua(%d)(%d)-",
        mysql = "^mysql(%d)(%d)-",
        pgsql = "^postgresql(9)(%d)-",
        pgsql1 = "^postgresql1(%d)-",
        php = "^php(%d)(%d)-",
        python2 = "^py(2)(%d)-",
        python3 = "^py(3)(%d)-",
        ruby = "^ruby(%d)(%d)-",
        tcltk = "^t[ck]l?(%d)(%d)-",
    }
    TRACE("DEFAULT_VERSION", origin_name, pkgname)
    for prog, pattern in pairs(T) do
        local major, minor = string.match(pkgname, pattern)
        if major then
            local default_version = prog .. "=" .. (minor and major .. "." .. minor or major)
            origin_name = origin_name .. "%" .. default_version
            TRACE("DEFAULT_VERSION->", origin_name, pkgname)
        end
    end
    return origin_name
end

-------------------------------------------------------------------------------------
local PACKAGES_CACHE = {} -- should be local with iterator ...
local PACKAGES_CACHE_LOADED = false -- should be local with iterator ...
-- setmetatable (PACKAGES_CACHE, {__mode = "v"})

local function shared_libs_cache_load()
    Msg.show {level = 2, start = true, "Load list of provided shared libraries"}
    local p = {}
    local lines = PkgDb.query {table = true, "%n-%v %b"}
    for _, line in ipairs(lines) do
        local pkgname, lib = string.match(line, "^(%S+) (%S+%.so%..*)")
        if pkgname then
            if pkgname ~= rawget(p, "name") then
                p = Package.get(pkgname) -- fetch cached package record
                p.shared_libs = {}
            end
            table.insert(p.shared_libs, lib)
        end
    end
    Msg.show {level = 2, "The list of provided shared libraries has been loaded"}
    Msg.show {level = 2, start = true}
end

local function req_shared_libs_cache_load()
    Msg.show {level = 2, start = true, "Load list of required shared libraries"}
    local p = {}
    local lines = PkgDb.query {table = true, "%n-%v %B"}
    for _, line in ipairs(lines) do
        local pkgname, lib = string.match(line, "^(%S+) (%S+%.so%..*)")
        if pkgname then
            if pkgname ~= rawget(p, "name") then
                p = Package.get(pkgname) -- fetch cached package record
                p.req_shared_libs = {}
            end
            table.insert(p.req_shared_libs, lib)
        end
    end
    Msg.show {level = 2, "The list of required shared libraries has been loaded"}
    Msg.show {level = 2, start = true}
end

-- load a list of of origins with flavor for currently installed flavored packages
local function packages_cache_load()
    if PACKAGES_CACHE_LOADED then
        return
    end
    local pkg_flavor = {}
    local pkg_fbsd_version = {}
    Msg.show {level = 2, start = true, "Load list of installed packages ..."}
    local lines = PkgDb.query {table = true, "%At %Av %n-%v"}
    if lines then
        for _, line in pairs(lines) do
            local tag, value, pkgname = string.match(line, "(%S+) (%S+) (%S+)")
            if tag == "flavor" then
                pkg_flavor[pkgname] = value
            elseif tag == "FreeBSD_version" then
                pkg_fbsd_version[pkgname] = value
            end
        end
    end
    -- load
    local pkg_count = 0
    lines = PkgDb.query {table = true, "%n-%v %o %q %a %k"} -- no dependent packages
    for _, line in ipairs(lines) do
        local pkgname, origin_name, abi, automatic, locked = string.match(line, "(%S+) (%S+) (%S+) (%d) (%d)")
        local f = pkg_flavor[pkgname]
        if f then
            origin_name = origin_name .. "@" .. f
        else
            origin_name = check_default_version(origin_name, pkgname)
        end
        local p = Package:new(pkgname)
        local o = Origin:new(origin_name)
        if not rawget(o, "old_pkgs") then
            o.old_pkgs = {}
        end
        o.old_pkgs[pkgname] = true
        p.origin = o
        p.abi = abi
        p.flavor = f
        p.is_automatic = automatic == "1"
        p.is_locked = locked == "1"
        p.is_installed = not Options.jailed
        p.num_depending = 0
        --p.dep_pkgs = {}
        p.fbsd_version = pkg_fbsd_version[pkgname]
        pkg_count = pkg_count + 1
    end
    Msg.show {level = 2, "The list of installed packages has been loaded (" .. pkg_count .. " packages)"}
    --[[
    Msg.show {level = 2, start = true, "Load package dependencies"}
    local p = {}
    lines = PkgDb.query {table = true, "%n-%v %rn-%rv"}
    for _, line in ipairs(lines) do
        local pkgname, dep_pkg = string.match(line, "(%S+) (%S+)")
        if pkgname ~= rawget(p, "name") then
            p = Package.get(pkgname) -- fetch cached package record
            p.dep_pkgs = {}
        end
        p.num_depending = p.num_depending + 1
        table.insert(p.dep_pkgs, dep_pkg)
    end
    Msg.show {level = 2, "Package dependencies have been loaded"}
    --]]
    Msg.show {level = 2, start = true}
    shared_libs_cache_load()
    req_shared_libs_cache_load()
    PACKAGES_CACHE_LOADED = true
end

--
local special_revs = {pl = true, alpha = true, beta = true, pre = true, rc = true}
local special_vals = {["*"] = -2, pl = -1, [""] = 0}

local function split_version_string(pkgname)
    local function alpha_tonumber(s)
        s = string.lower(s)
        return special_vals[s] or string.byte(s, 1, 1) - 96 -- subtract one less than ASCII "a" == 0x61 == 97
    end
    local result = {}
    local function store_results(n1, a1, n2)
        local rn = #result
        result[rn+1] = n1 ~= "" and tonumber(n1) or -1
        result[rn+2] = alpha_tonumber(a1)
        result[rn+3] = n2 ~= "" and tonumber(n2) or 0
    end
    local version = string.match(pkgname, ".*[%a%d%*]")
    local s, revision, epoch = string.match (version, "([^_,]*)_?([^,]*),?(.*)")
    version = s or version
    for n1, a1, n2 in string.gmatch(version, "(%d*)([%a%*]*)(%d*)") do
        if special_revs[a1] then
            store_results(n1, "", "")
            n1 = ""
        end
        store_results(n1, a1, n2)
    end
    result.epoch = tonumber(epoch) or 0
    result.revision = tonumber(revision) or 0
    return result
end

--
local function compare_versions(p1, p2)
    local function compare_lists(t1, t2)
        local n1 = #t1
        local n2 = #t2
        local n = n1 > n2 and n1 or n2
        for i = 1, n do
            local delta = (t1[i] or 0) - (t2[i] or 0)
            if delta ~= 0 then
                return delta
            end
        end
        return 0
    end
    TRACE("COMPARE_VERSIONS", p1.name, p2.name)
    local result
    if p1 and p2 then
        local vs1 = p1.version
        local vs2 = p2.version
        if vs1 ~= vs2 then
            local v1 = split_version_string(vs1)
            local v2 = split_version_string(vs2)
            result = v1.epoch - v2.epoch
            result = result ~= 0 and result or compare_lists(v1, v2)
            result = result ~= 0 and result or v1.revision - v2.revision
        else
            result = 0
        end
    end
    TRACE("COMPARE_VERSIONS->", result, p1.name, p2.name)
    return result
end

--
local function get(pkgname)
    return PACKAGES_CACHE[pkgname]
end

--
local function installed_pkgs()
    packages_cache_load()
    local result = {}
    for k, v in pairs(PACKAGES_CACHE) do
        if v.is_installed or Options.jailed then
            table.insert(result, PACKAGES_CACHE[k])
        end
    end
    return result
end

--
local function __newindex(pkg, n, v)
    TRACE("SET(p)", pkg.name, n, v)
    rawset(pkg, n, v)
end

local function __index(pkg, k)
    local function __pkg_vars(pkg, k)
        local function set_field(field, v)
            if v == "" then
                v = false
            end
            pkg[field] = v
        end
        local t = PkgDb.query {table = true, "%q\n%k\n%a\n%#r", pkg.name_base}
        set_field("abi", t[1])
        set_field("is_locked", t[2] == "1")
        set_field("is_automatic", t[3] == "1")
        set_field("num_depending", tonumber(t[4]))
        return pkg[k]
    end
    local function load_num_dependencies(pkg, k)
        Msg.show {level = 2, start = true, "Load dependency counts"}
        local t = PkgDb.query {table = true, "%#d %n-%v"}
        for _, line in ipairs(t) do
            local num_dependencies, pkgname = string.match(line, "(%d+) (%S+)")
            PACKAGES_CACHE[pkgname].num_dependencies = tonumber(num_dependencies)
        end
        Msg.show {level = 2, "Dependency counts have been loaded"}
        Msg.show {level = 2, start = true}
        return pkg[k]
    end

    local dispatch = {
        abi = __pkg_vars,
        is_automatic = __pkg_vars,
        is_locked = __pkg_vars,
        num_depending = __pkg_vars,
        num_dependencies = load_num_dependencies,
        -- flavor = get_attribute,
        -- FreeBSD_version = get_attribute,
        name_base = pkg_basename,
        name_base_major = pkg_strip_minor,
        version = pkg_version,
        pkgfile = pkg_lookup,
        bakfile = pkg_lookup,
        pkgfile_abi = function(pkg, v)
            return file_get_abi(filename {pkg}) or false
        end,
        -- bakfile_abi = file_get_abi,
        shared_libs = function(pkg, k)
            return PkgDb.query {table = true, "%b", pkg.name} -- should be cached!!!
        end,
        req_shared_libs = function(pkg, k)
            return PkgDb.query {table = true, "%B", pkg.name} -- should be cached!!!
        end,
        is_installed = function(pkg, k)
            return false -- always explicitly set when found or during installation
        end,
        --[[
        files = function (pkg, k)
            return PkgDb.query {table = true, "%Fp", pkg.name}
        end,
        categories = function (pkg, k)
            error ("should be cached")
            return PkgDb.query {table = true, "%C", pkg.name}
        end,
      --]]
        pkg_filename = function(pkg, k)
            return filename {subdir = "All", pkg}
        end,
        bak_filename = function(pkg, k)
            return filename {subdir = "portmaster-backup", ext = PARAM.backup_format, pkg}
        end,
        --[[
        origin = function (pkg, k)
            error ("should be cached")
            TRACE ("Looking up origin for", pkg.name)
            local port = PkgDb.query {"%o", pkg.name}
            if port ~= "" then
                local flavor = pkg.flavor
                local n = flavor and port .. "@" .. flavor or port
                return Origin:new (n)
            end
        end,
        --]]
    }

    TRACE("INDEX(p)", pkg, k)
    local w = rawget(pkg.__class, k)
    if w == nil then
        rawset(pkg, k, false)
        local f = dispatch[k]
        if f then
            w = f(pkg, k)
            if w then
                rawset(pkg, k, w)
            else
                w = false
            end
        else
            -- error("illegal field requested: Package." .. k)
        end
        TRACE("INDEX(p)->", pkg, k, w)
    else
        TRACE("INDEX(p)->", pkg, k, w, "(cached)")
    end
    return w
end

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache()
    local t = PACKAGES_CACHE
    for _, v in ipairs(table.keys(t)) do
        TRACE("PACKAGES_CACHE", v, t[v])
    end
end

local mt = {
    __index = __index,
    __newindex = __newindex, -- DEBUGGING ONLY
    __tostring = function(self)
        return self.name
    end,
}

-- create new Package object or return existing one for given name
local function new(Package, name)
    -- local TRACE = print -- TESTING
    -- assert (type (name) == "string", "Package:new (" .. type (name) .. ")")
    if name then
        local P = PACKAGES_CACHE[name]
        if not P then
            P = {name = name}
            P.__class = Package
            setmetatable(P, mt)
            PACKAGES_CACHE[name] = P
            TRACE("NEW Package", name)
        else
            TRACE("NEW Package", name, "(cached)")
        end
        return P
    end
    return nil
end

-------------------------------------------------------------------------------------
return {
    name = false,
    new = new,
    get = get,
    installed_pkgs = installed_pkgs,
    backup_delete = backup_delete,
    -- backup_create = backup_create,
    delete_old = delete_old,
    recover = recover,
    category_links_create = category_links_create,
    file_search = file_search,
    -- file_get_abi = file_get_abi,
    -- check_use_package = check_use_package,
    check_excluded = check_excluded,
    message = message,
    backup_old_package = backup_old_package,
    deinstall = deinstall,
    install = install,
    shlibs_backup = shlibs_backup,
    shlibs_backup_remove_stale = shlibs_backup_remove_stale,
    automatic_set = automatic_set,
    packages_cache_load = packages_cache_load,
    dump_cache = dump_cache,
    filename = filename,
    compare_versions = compare_versions,
}

--[[
   Instance variables of class Package:
   - abi = abi of package as currently installed
   - categories = table of registered categories of this package
   - files = table of installed files of this package
--   - pkg_filename = name of the package file
--   - bak_filename = name of the backup file
   - shlibs = table of installed shared libraries of this package
   - is_automatic = boolean value whether this package has been automaticly installed
   - is_locked = boolean value whether this package is locked
   - num_dependencies = the number of packages required to run this package
   - num_depending = the number of other packages that depend on this one
   - origin = the origin string this package has been built from
--]]
