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
--local Origin = require ("portmaster.origin")
local Excludes = require("portmaster.excludes")
local Options = require("portmaster.options")
local PkgDb = require("portmaster.pkgdb")
local Msg = require("portmaster.msg")
local Exec = require("portmaster.exec")
local CMD = require("portmaster.cmd")
local Param = require("portmaster.param")
local Trace = require("portmaster.trace")
local Filepath = require("portmaster.filepath")

local TRACE = Trace.trace

-------------------------------------------------------------------------------------
-- the Package class describes a package with optional package file

--
local function pkg_filepath(args)
    local pkg = args[1]
    local pkgname = pkg.name
    local base = args.base or Param.packages
    local subdir = args.subdir or "All"
    local extension = args.ext or Param.package_format
    if string.sub(extension, 1, 1) ~= "." then
        extension = "." .. extension
    end
    local result = base + subdir + (pkgname .. extension)
    --TRACE("FILENAME->", result, base, subdir, pkgname, extension)
    return result
end

-------------------------------------------------------------------------------------
-- remove from shlib backup directory all shared libraries replaced by new versions
-- preserve currently installed shared libraries // <se> check name of control variable
local function shlibs_backup(pkg)
    local pkg_libs = pkg.shared_libs
    --TRACE("SHLIBS_BACKUP", pkg.name, pkg_libs, pkg)
    if pkg_libs then
        local ldconfig_lines = Exec.run{ -- "RT?" ??? CACHE LDCONFIG OUTPUT???
            table = true,
            safe = true,
            CMD.ldconfig, "-r"
        }
        for _, line in ipairs(ldconfig_lines) do
            local libpath, lib = string.match(line, " => (" .. Param.local_lib.name .. "*(lib.*%.so%..*))")
            if lib then
                local libfile = Filepath:new(libpath)
                --TRACE("SHLIBS_BACKUP+", libpath, lib, stat, mode)
                if libfile.is_reg then
                    for _, l in ipairs(pkg_libs) do
                        if l == lib then
                            local backup_lib = Param.local_lib_compat + lib
                            if backup_lib.is_readable then
                                Exec.run{
                                    as_root = true,
                                    log = true,
                                    CMD.unlink, backup_lib.name
                                }
                            end
                            local out, err, exitcode = Exec.run{
                                as_root = true,
                                log = true,
                                CMD.cp, libpath, backup_lib.name
                            }
                            --TRACE("SHLIBS_BACKUP", tostring(out), err)
                            if exitcode ~= 0 then
                                return out, err
                            end
                        end
                    end
                else
                    --TRACE("SHLIBS_BACKUP-", libpath, lib, stat, mode)
                end
            end
        end
    end
    return true
end

-- remove from shlib backup directory all shared libraries replaced by new versions
local function shlibs_backup_remove_stale(pkg)
    local pkg_libs = pkg.shared_libs
    --TRACE("BACKUP_REMOVE_SHARED", pkg_libs, pkg)
    if pkg_libs then
        local deletes = {}
        for _, lib in ipairs(pkg_libs) do
            local backup_lib = Param.local_lib_compat + lib
            if backup_lib.is_readable then
                table.insert(deletes, backup_lib.name)
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
    end
end

-------------------------------------------------------------------------------------
-- deinstall named package (JAILED)
local function backup_old_package(package)
    local pkgname = package.name
    return Exec.pkg{
        as_root = Param.packages_ro,
        "create", "-q", "-o", Param.packages_backup.name, "-f", Param.backup_format, pkgname
    }
end

--
local function deinstall(package)
    local pkgname = package.name
    local from_jail = Options.jailed and Param.phase ~= "install"
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
    if not Options.dry_run and (not Options.jailed or Param.phase == "install") then
        local msg = PkgDb.query {"%M", pkg.name}
        if type(msg) == "string" then
            return msg
        end
    end
end

-------------------------------------------------------------------------------------
-- install package from passed pkg
local function install(pkg, abi)
    local pkgfile = pkg.pkgfile.name
    local jailed = Options.jailed and Param.phase == "build"
    local env = {IGNORE_OSVERSION = "yes"}
    TRACE("INSTALL", abi, pkgfile)
    if string.match(pkgfile, ".*/pkg-[^/]+$") then -- pkg command itself
        if not Filepath.is_executable(CMD.pkg) then
            env.ASSUME_ALWAYS_YES = "yes"
            local out, err, exitcode = Exec.run{
                as_root = true,
                jailed = jailed, -- ???
                log = true,
                env = env,
                CMD.pkg_bootstrap, "bootstrap"
            }
            if exitcode ~= 0 then
                return out, err, exitcode
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
    local extension = Param.package_format
    local source = pkg_filepath{base = Filepath:new(".."), ext = extension, pkg_new}
    table.insert(categories, "Latest")
    for _, category in ipairs(categories) do
        local destination = Param.packages + category
        if not destination.is_dir then
            Exec.run{
                as_root = Param.packages_ro,
                log = true,
                CMD.mkdir, "-p", destination.name
            }
        end
        if category == "Latest" then -- skip if/since automatically created???
            destination = destination + (pkg_new.name_base .. "." .. extension)
        end
        TRACE("LN", source, destination)
        Exec.run{
            as_root = Param.packages_ro,
            log = true,
            CMD.ln, "-sf", source.name, destination.name
        }
    end
end

--
-- re-install package from backup after attempted installation of a new version failed
local function recover(pkg)
    -- if not pkgname then return true end
    local pkgname = pkg.name
    local pkgfile = pkg.pkgfile.name
    if not pkgfile then
        pkgfile = Exec.run{
            table = true,
            safe = true,
            CMD.ls, "-1t", pkg_filepath{base = Param.packages_backup, subdir = "", ext = ".*", pkg}.name -- XXX replace with glob and sort by modification time ==> pkg.bakfile
        }[1]
    end
    if pkgfile and Filepath.is_readable(pkgfile) then
        Msg.show {"Re-installing previous version", pkgname}
        if install(pkg, pkg.pkgfile_abi) then
            if pkg.is_automatic == 1 then
                pkg:automatic_set(true)
            end
            shlibs_backup_remove_stale(pkg)
            --[[ Exec.run{ -- required ???
                as_root = true,
                log = true,
                CMD.unlink, Param.packages_backup .. pkgname .. ".t?*"
            }--]]
            return true
        end
    end
    Msg.show {"Recovery from backup package file", pkgfile, "failed"}
end

-- search package file in directory
local function file_search_in(pkg, subdir)
    local files = pkg_filepath{subdir = subdir, ext = ".t?*", pkg}.files
    TRACE("FILE_SEARCH_IN", files)
    local file
    for _, f in ipairs(files) do
        if not file or file.mtime < f.mtime then -- newer than previously checked package file?
            file = f
        end
    return file -- XXX check callers
    end
end

--[[
-- search package file
local function file_search(pkg)
    return file_search_in(pkg, "All") or file_search_in(pkg, "package-backup")
end
--]]

-- delete backup package file
local function backup_delete(pkg)
    local files = pkg_filepath{subdir = "portmaster-backup", ext = ".t?*", pkg}.files
    for _, backupfile in pairs(files) do
        --TRACE("BACKUP_DELETE", backupfile, Param.packages .. "portmaster-backup/")
        Exec.run{
            as_root = true,
            log = true,
            CMD.unlink, backupfile.name
        }
    end
end

-- delete stale package file ==> convert to be based on pkg.pkgfile and pkg.bakfile XXX
local function delete_old(pkg)
    local bakfile_name = pkg.bakfile
    local files = pkg_filepath{subdir = "*", ext = "t?*", pkg}.files
    --TRACE("DELETE_OLD", pkg.name, g)
    for _, pkgfile in pairs(files) do
        --TRACE("CHECK_BACKUP", pkgfile, bakfile)
        local pkgfile_name = pkgfile.name
        if pkgfile_name ~= bakfile_name then
            Exec.run{
                as_root = true,
                log = true,
                CMD.unlink, pkgfile_name
            }
        end
    end
end

-------------------------------------------------------------------------------------
-- return true (exit code 0) if named package is locked
-- set package to auto-installed if automatic == 1, user-installed else
local function automatic_set(pkg, automatic)
    --TRACE("AUTOMATIC_SET", pkg, automatic)
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
        lua = "^lua(%d)(%d)-",
        mysql = "^mysql(%d)(%d)-",
        pgsql = "^postgresql(9)(%d)-",
        pgsql1 = "^postgresql1(%d)-",
        php = "^php(%d)(%d)-",
        python2 = "^py(2)(%d)-",
        python3 = "^py(3)(%d)-",
        ruby = "^ruby(%d)(%d)-",
        tcltk = "^t[ck]l?(%d)(%d)-",
    }
    --TRACE("DEFAULT_VERSION", origin_name, pkgname)
    for prog, pattern in pairs(T) do
        local major, minor = string.match(pkgname, pattern)
        if major then
            local default_version = prog .. "=" .. (minor and major .. "." .. minor or major)
            origin_name = origin_name .. "%" .. default_version
            --TRACE("DEFAULT_VERSION->", origin_name, pkgname)
        end
    end
    return origin_name
end

-------------------------------------------------------------------------------------
--local PACKAGES_VERSIONS = {}
local PACKAGES_CACHE = {} -- should be local with iterator ...
local PACKAGES_CACHE_LOADED = false -- should be local with iterator ...
-- setmetatable (PACKAGES_CACHE, {__mode = "v"})

--
local function get(pkgname)
    return PACKAGES_CACHE[pkgname]
end

--
local function shared_libs_cache_load()
    Msg.show {level = 2, start = true, "Load list of shared libraries provided by packages"}
    local p = {}
    local lines = PkgDb.query {table = true, "%n-%v %b"}
    for _, line in ipairs(lines) do
        local pkgname, lib = string.match(line, "^(%S+) (%S+%.so%..*)")
        if pkgname then
            if pkgname ~= rawget(p, "name") then
                p = get(pkgname) -- fetch cached package record
                p.shared_libs = {}
            end
            table.insert(p.shared_libs, lib)
        end
    end
    Msg.show {level = 2, "The list of provided shared libraries has been loaded"}
    Msg.show {level = 2, start = true}
end

local function req_shared_libs_cache_load()
    Msg.show {level = 2, start = true, "Load list of shared libraries required by packages"}
    local p = {}
    local lines = PkgDb.query {table = true, "%n-%v %B"}
    for _, line in ipairs(lines) do
        local pkgname, lib = string.match(line, "^(%S+) (%S+%.so%..*)")
        if pkgname then
            if pkgname ~= rawget(p, "name") then
                p = get(pkgname) -- fetch cached package record
                p.req_shared_libs = {}
            end
            table.insert(p.req_shared_libs, lib)
        end
    end
    Msg.show {level = 2, "The list of required shared libraries has been loaded"}
    Msg.show {level = 2, start = true}
end

-- load a list of of origins with flavor for currently installed flavored packages
local function packages_cache_load(Package)
    if PACKAGES_CACHE_LOADED then
        return PACKAGES_CACHE
    end
    local pkg_flavor = {}
    local pkg_fbsd_version = {}
    Msg.show {level = 2, start = true, "Load list of installed packages ..."}
    local lines = PkgDb.query {table = true, "%At %Av %n-%v"}
    if lines then
        for _, line in ipairs(lines) do
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
        p.origin_name = origin_name
        p.installed_abi = abi
        p.flavor = f
        p.is_automatic = automatic == "1"
        p.is_locked = locked == "1"
        p.is_installed = not Options.jailed
        p.num_depending = 0
        p.fbsd_version = pkg_fbsd_version[pkgname]
        pkg_count = pkg_count + 1
    end
    Msg.show {level = 2, "The list of installed packages has been loaded (" .. pkg_count .. " packages)"}
    Msg.show {level = 2, start = true, "Load package dependencies"}
    local p = {}
    lines = PkgDb.query {table = true, "%n-%v %rn-%rv"}
    for _, line in ipairs(lines) do
        local pkgname, dep_pkg = string.match(line, "(%S+) (%S+)")
        if pkgname ~= rawget(p, "name") then
            p = get(pkgname) -- fetch cached package record
            p.dep_pkgs = {}
        end
        p.num_depending = p.num_depending + 1
        table.insert(p.dep_pkgs, dep_pkg) -- XXX actually used ???
    end
    Msg.show {level = 2, "Package dependencies have been loaded"}
    Msg.show {level = 2, start = true}
    shared_libs_cache_load()
    req_shared_libs_cache_load()
    PACKAGES_CACHE_LOADED = true
    return PACKAGES_CACHE
end

-------------------------------------------------------------------------------------
--
local function __newindex(pkg, n, v)
    TRACE("SET(p)", pkg.name, n, v)
    rawset(pkg, n, v)
end

local function __index(pkg, k)
    local function __origin_from_pkg(pkg, k)
        TRACE("ORIGIN_FROM_PKG", k, pkg)
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
    local function __pkgfile_abi(pkg, v)
        return PkgDb.query{pkgfile = pkg_filepath{pkg}.name, "%q"} or false
    end
    local function __pkg_filename(pkg, v)
        return pkg_filepath{subdir = "All", pkg}
    end
    local function __bak_filename(pkg, v)
        return pkg_filepath{subdir = "portmaster-backup", ext = Param.backup_format, pkg}
    end
    -- lookup package file
    local function __pkg_lookup(pkg, k)
        return file_search_in(pkg, "All")
    end
    local function __bak_lookup(pkg, k)
        return file_search_in(pkg, "portmaster-backup")
    end
    local function __default_true()
       return true
    end
    local function __default_false()
       return false
    end
    local function __default_zero()
        return 0
    end
    -- return package version
    local function __pkg_version(pkg, v)
        local version = (string.match(pkg.name, ".*-([^-]+)"))
        --TRACE("VERSION", pkg.name, v)
        return version
    end
    -- return package basename without version
    local function __pkg_basename(pkg, v)
        return (string.match(pkg.name, "(%S+)-"))
    end
    -- return package name with only the first part of the version number
    local function __pkg_strip_minor(pkg, v)
        local major = string.match(pkg.version, "([^.]+)%.%S+")
        local result = pkg.name_base .. "-" .. (major or "")
        --TRACE("STRIP_MINOR", pkg.name, result)
        return result
    end
    local function __origin_name()
        TRACE("GET ORIGIN_NAME", rawget(pkg, "origin_name"), pkg)
        return rawget(pkg, "origin_name")
    end
    local dispatch = {
        installed_abi = __default_false,
        is_automatic = __default_true,
        is_locked = __default_false,
        num_depending = __default_zero,
        num_dependencies = load_num_dependencies,
        -- flavor = get_attribute, -- batch loaded at start
        -- FreeBSD_version = get_attribute, -- batch loaded at start
        origin_name = __origin_name,
        name_base = __pkg_basename,
        name_base_major = __pkg_strip_minor,
        version = __pkg_version,
        pkgfile = __pkg_lookup,
        bakfile = __bak_lookup,
        pkgfile_abi = __pkgfile_abi,
        -- bakfile_abi = file_get_abi, -- UNUSED XXX
        --shared_libs = false, -- batch loaded at start
        --req_shared_libs = false, -- batch loaded at start
        --is_installed = false, -- set for files loaded from package db
        --depends = __depends,
        pkg_filename = __pkg_filename,
        bak_filename = __bak_filename,
    }

    --TRACE("INDEX(p)", pkg, k)
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
        --TRACE("INDEX(p)->", pkg, k, w)
    else
        --TRACE("INDEX(p)->", pkg, k, w, "(cached)")
    end
    return w
end

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache()
    local t = PACKAGES_CACHE
    for k, v in pairs(t) do
        TRACE("PACKAGES_CACHE", k, v)
    end
end

local mt = {
    __index = __index,
    --__newindex = __newindex, -- DEBUGGING ONLY
    __tostring = function(self)
        return self.name
    end,
}

-- create new Package object or return existing one for given name
local function new(Package, name)
    -- assert (type (name) == "string", "Package:new (" .. type (name) .. ")")
    if name then
        local P = PACKAGES_CACHE[name]
        if not P then
            P = {name = name}
            P.__class = Package
            setmetatable(P, mt)
            PACKAGES_CACHE[name] = P
            --[[
            local basename = pkg_basename(P) -- XXX EXPERIMENTAL PACKAGE VERSIONS TABLE
            local v = PACKAGES_VERSIONS[basename] or {}
            v[#v + 1] = name
            PACKAGES_VERSIONS[basename] = v
            --TRACE("V", basename, v)
            --]]
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
    backup_delete = backup_delete,
    -- backup_create = backup_create,
    delete_old = delete_old,
    recover = recover,
    category_links_create = category_links_create,
    -- file_search = file_search,
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
}
