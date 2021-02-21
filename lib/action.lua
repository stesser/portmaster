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
local Origin = require("portmaster.origin")
local Options = require("portmaster.options")
local PkgDb = require("portmaster.pkgdb")
local Msg = require("portmaster.msg")
local Exec = require("portmaster.exec")
local Lock = require("portmaster.lock")
local CMD = require("portmaster.cmd")
local Param = require("portmaster.param")
local Moved = require("portmaster.moved")
local Excludes = require("portmaster.excludes")

-------------------------------------------------------------------------------------
local P = require("posix")
local glob = P.glob

local P_US = require("posix.unistd")
local access = P_US.access

-------------------------------------------------------------------------------------
local ACTION_CACHE = {}
local ACTION_LIST = {}

--
local function list()
    return ACTION_LIST
end

-- return the sum of the numbers of required operations
local function tasks_count()
    return #ACTION_LIST
end

--
local function origin_changed(o_o, o_n) -- move to Origin package !!!
    return o_o and o_o.name ~= "" and o_o ~= o_n and o_o.name ~= string.match(o_n.name, "^([^%%]+)%%")
end

--
local function action_set(action, verb)
    --TRACE("ACTION_SET", action.pkg_new or action.old_pkgs[1], verb)
    verb = verb ~= "keep" and verb ~= "exclude" and verb or false
    action.action = verb
end

--
local function action_get(action)
    return action.action or "keep"
end

-- check whether the action denoted by "verb" has been registered
local function action_is(action, verb)
    local a = action_get(action)
    TRACE ("ACTION_IS", action.pkg_new or action.old_pkgs[1], a, verb)
    if action.ignore then
        return verb == "exclude" or verb == "keep" or not verb
    end
    return verb and a == verb
end

-- Describe action to be performed
local function describe(action)
    local p_n = action.pkg_new
    local old_pkgs = action.old_pkgs -- XXX update for multiple old packages !!!
    local n_old = #old_pkgs
    TRACE("DESCRIBE", rawget(p_n or {}, "name"), action)
    local text
    if action.do_deinstall then
        assert(n_old == 1)
        local p_o = old_pkgs[1]
        local reason = rawget (p_o.origin, "reason") or
            "Port directory " .. p_o.origin.port .. " has been deleted"
        text = "Deinstall " .. p_o.name .. " (" .. reason .. ")"
    elseif action.do_upgrade then
        local verb
        if n_old == 0 then
            verb = "Install"
        elseif action.do_build then
            verb = "Upgrade"
        elseif action.do_pkgcreate then
            verb = "Create package"
        elseif action.do_provide then
            verb = "Provide"
        else
            verb = "???UNDEF???"
        end
        if n_old == 0 then
            text = verb .. " " .. p_n.name .. " from " .. p_n.origin.name
        else
            text = verb .. " "
            for i, p_o in ipairs(old_pkgs) do
                if i > 1 then
                    text = text .. ", "
                end
                text = text .. p_o.name
                if p_o.origin.name ~= p_n.origin.name then
                    text = text .. " (" .. p_o.origin.name .. ")"
                end
            end
            text = text .. " to " .. p_n.name
            if action.use_pkgfile then
                text = text .. " from " .. p_n.pkg_filename
            else
                text = text .. " from " .. p_n.origin.name
            end
        end
    end
    return text
    --[[
    if action.do_deinstall then
        return string.format("De-install %s built from %s", p_o.name, o_o.short_name)
    elseif action_is(action, "change") then
        if p_o ~= p_n then
            local prev_origin = o_o and o_o ~= o_n and " (was " .. o_o.short_name .. ")" or ""
            return string.format("Change package name from %s to %s for port %s%s",
                                    p_o.name, p_n.name, o_n.short_name, prev_origin)
        else
            return string.format("Change origin of port %s to %s for package %s", o_o.short_name, o_n.short_name, p_n.name)
        end
    elseif action_is(action, "exclude") and p_o then
        return string.format("Skip excluded package %s installed from %s", p_o.name, o_o.short_name)
    elseif action_is(action, "upgrade") then
        local from
        if p_n and p_n.pkgfile then
            from = "from " .. p_n.pkgfile
        else
            from = "using " .. o_n.short_name .. (origin_changed(o_o, o_n) and " (was " .. o_o.short_name .. ")" or "")
        end
        local prev_pkg = ""
        local verb
        if not p_o then
            verb = "Install"
        else
            local vers_cmp = action.vers_cmp
            if p_o == p_n then
                verb = "Re-install"
            else
                if action.pkg_old.name_base == action.pkg_new.name_base then
                    if vers_cmp < 0 then
                        verb = "Upgrade"
                    elseif vers_cmp > 0 then
                        verb = "Downgrade"
                    end
                    prev_pkg = p_o.name .. " to "
                else
                    verb = "Replace"
                    prev_pkg = p_o.name .. " with "
                end
            end
        end
        return string.format("%s %s%s %s", verb, prev_pkg, p_n.name, from)
    end
    return "No action for " .. action.short_name
    --]]
end

--
local previous_action_co

local function log(action, args)
    --TRACE("LOG", args, action)
    if Param.phase ~= "scan" then
        if not rawget(action, "startno_string") then
            action.startno_string = "[" .. tostring(action.startno) .. "/" .. tostring(#ACTION_LIST) .. "]"
            TRACE("STARTNO", action.startno_string, action.listpos, action.short_name)
            action:log { start = true, "START:", describe(action)}
            args.start = nil
        end
        local co = coroutine.running()
        args.start = args.start or co ~= previous_action_co
        previous_action_co = co
        table.insert(args, 1, action.startno_string)
        table.insert(args, 2, action.short_name .. ":")
    end
    --TRACE("LOG", args)
    Msg.show(args)
end

-------------------------------------------------------------------------------------
-- record failure of an action and return false
local function fail(action, msg, errlog)
    if not rawget(action, "failed_msg") then
        action.failed_msg = msg
        TRACE("SET_FAILED", msg, action)
    end
    if errlog then
        if rawget(action, "failed_log") then
            errlog = action.failed_log .. "\n" .. errlog
        end
        action.failed_log = errlog
    end
    return false
end

local function failed(action)
    --TRACE("CHK_FAILED", action.pkg_new.name , rawget(action, "failed_msg"), rawget(action, "failed_log"))
    return rawget(action, "failed_msg"), rawget(action, "failed_log")
end

-------------------------------------------------------------------------------------
-- rename all matching package files (excluding package backups)
local function pkgfiles_rename(action) -- UNTESTED !!!
    local p_n = action.pkg_new
    local old_pkgs = action.old_pkgs
    if #old_pkgs ~= 1 then
        return fail(action, "Zero or more than 1 old package passed to pkgfiles_rename")
    end
    local p_o = old_pkgs[1]
    assert(p_o, "No old package passed to pkgfiles_rename()")
    --TRACE("PKGFILES_RENAME", action, p_o.name, p_n.name)
    local file_pattern = Package.filename {subdir = "*", ext = "t?*", p_o}
    --TRACE("PKGFILES_RENAME-Pattern", file_pattern)
    local pkgfiles = glob(file_pattern)
    if pkgfiles then
        for _, pkgfile_old in ipairs(pkgfiles) do
            if access(pkgfile_old, "r") and not strpfx(pkgfile_old, Param.packages_backup) then
                local pkgfile_new = path_concat(dirname(pkgfile_old), p_n.name .. pkgfile_old:gsub(".*(%.%w+)", "%1"))
                local _, err, exitcode =
                    Exec.run {
                    as_root = true,
                    log = true,
                    CMD.mv,
                    pkgfile_old,
                    pkgfile_new
                }
                if exitcode ~= 0 then
                    fail(action, "Failed to rename package file from " .. pkgfile_old .. " to " .. pkgfile_new, err)
                end
            end
        end
    end
    return not failed(action)
end

-------------------------------------------------------------------------------------
-- convert origin with flavor to sub-directory name to be used for port options
-- move the options file if the origin of a port is changed
local function portdb_update_origin(action)
    assert(#action.old_pkgs == 1, "portdb_update_origin called with 0 or >1 old origin")
    local o_o = action.old_pkgs[1].origin -- XXX should be called with specific origin !!!
    local portdb_dir_old = o_o:portdb_path()
    if is_dir(portdb_dir_old) and access(portdb_dir_old .. "/options", "r") then
        local o_n = action.pkg_new.origin
        if o_n then
            local portdb_dir_new = o_n:portdb_path()
            if is_dir(portdb_dir_new) then
                return fail(action, "Target directory does already exist")
            end
            local _, err, exitcode =
                Exec.run {
                as_root = true,
                log = true,
                CMD.mv,
                portdb_dir_old,
                portdb_dir_new
            }
            if exitcode ~= 0 then
                return fail(action, "Failed to rename " .. portdb_dir_old .. " to " .. portdb_dir_new .. " in the package database", err)
            end
        end
    end
    return true
end

--[=[
-- check for build conflicts immediately before a port build is started
local function check_build_conflicts(action)
    local origin = action.o_n
    local build_conflicts = origin.build_conflicts
    local result = {}
    --
    for i, pattern in ipairs(pattern_list) do
        for j, pkgname in ipairs(PkgDb.query {
            table = true,
            glob = true,
            "%n-%v",
            pattern
        }) do table.insert(result, pkgname) end
    end
    -- ]]
    return result
end
--]=]

-- create package file from staging area of previously built port
local function package_create(action)
    local o_n = action.pkg_new and action.pkg_new.origin
    local pkgname = action.pkg_new.name
    local pkgfile = action.pkg_new.pkg_filename -- (Param.packages .. "All", pkgname, Param.package_format)
    --TRACE("PACKAGE_CREATE", o_n, pkgname, pkgfile)
    if Options.skip_recreate_pkg and access(pkgfile, "r") then
        action:log {"The existing package file will not be overwritten"}
    else
        action:log {"Create a package from staging area of port", o_n.name}
        local jailed = Options.jailed
        local as_root = Param.packages_ro
        local base = (as_root or jailed) and Param.tmpdir or Param.packages -- use random tempdir !!!
        local sufx = "." .. Param.package_format
        local _, err, exitcode =
            o_n:port_make {
            log = true,
            jailed = jailed,
            "_OPTIONS_OK=1",
            "PACKAGES=" .. base,
            "PKG_SUFX=" .. sufx,
            "package"
        }
        if exitcode == 0 then
            if as_root or jailed then
                local tmpfile = path_concat(base, "All", pkgname .. sufx)
                if jailed then
                    tmpfile = path_concat(Param.jailbase, tmpfile)
                end
                if as_root then
                    Exec.run {
                        as_root = true,
                        CMD.chown,
                        "0:0",
                        tmpfile
                    }
                end
                _, err, exitcode =
                    Exec.run {
                    as_root = as_root,
                    CMD.mv,
                    tmpfile,
                    pkgfile
                }
            end
        end
        if exitcode ~= 0 or not Options.dry_run and not access(pkgfile, "r") then
            return fail(action, "Package file " .. pkgfile .. " could not be created", err)
        end
        action.pkg_new:category_links_create(o_n.categories)
        action:log {"Package saved to file", pkgfile}
    end
    return true
end

-- check conflicts of new port with installed packages (empty table if no conflicts found)
local function conflicting_pkgs(action, mode)
    local o_n = action.pkg_new and action.pkg_new.origin
    if o_n and o_n.build_conflicts and o_n.build_conflicts[1] then
        local result = {}
        local make_target = mode == "build_conflicts" and "check-build-conflicts" or "check-conflicts"
        local conflicts_table, err, exitcode =
            o_n:port_make {
            table = true,
            safe = true,
            make_target
        }
        if exitcode == 0 then
            for _, line in ipairs(conflicts_table) do
                --TRACE("CONFLICTS", line)
                local pkgname = line:match("^%s+(%S+)%s*")
                if pkgname then
                    table.insert(result, Package:new(pkgname))
                elseif #result > 0 then
                    break
                end
            end
        end
        return result
    end
end

-------------------------------------------------------------------------------------
--
local function get(pkgname)
    return rawget(ACTION_CACHE, pkgname)
end

-------------------------------------------------------------------------------------
-- perform all steps required to build a port (extract, patch, build, stage, opt. package)

-- de-install (possibly partially installed) port after installation failure
local function deinstall_failed_port(action)
    local o_n = action.pkg_new.origin
    action:log {"Installation from", o_n.name, "failed, deleting partially installed package"}
    local out, err, exitcode =
        o_n:port_make {
        log = true,
        jailed = true,
        as_root = true,
        "deinstall"
    }
    return exitcode == 0
end

--[[
(1) wait for fetch+checksum to complete for all distfiles (fetch_lock)
(2) wait for build dependencies to become available (from port or package)
(3) lock work directory for port (independently of flavor or DEFAULT_VERSIONS)
    extract and patch into work directory
    build port and install into staging area
    if all run dependencies are available (try_acquire) then
        create package (if requested)
(2)     signal package available
        if old version is installed
            create backup package
            deinstall old version
        install from stage directory (in jail only if dependency of later port)
        if installation succeeded
(2)         signal new version is installed and available
            delete backup package if not to be kept
        else
            reinstall from backup package
            delete backup package
    else
        create package for later installation
(2)     signal package available
    clean work directory
(3) release lock on work directory
--]]
--
local WorkDirLock
local RunnableLock
local JobsLock

-- install or upgrade a port - now also performs deinstall!!!
local function perform_install_or_upgrade(action)
    local old_pkgs = action.old_pkgs
    local p_n = action.pkg_new
    local pkgname_new = p_n and p_n.name
    local pkgfile = p_n and p_n.pkgfile
    local o_n = p_n and p_n.origin
    local portname = o_n and o_n.name -- o_n.port ???
    --local build_depends = o_n and o_n.depends.build
    --local pkg_depends = o_n and o_n.depends.run or { "ports-mgmt/pkg" }
    --local run_depends = o_n and o_n.depends.run or {}
    local special_depends = o_n and o_n.special_depends -- check for special license and ask user to accept it (may require make extract/patch)
    local build_dep_pkgs

    local function wait_for_distfiles()
        o_n:fetch_wait()
    end
    local function check_license()
        -- may depend on OPTIONS set by make configure
        if not Param.disable_licenses then
            if not o_n:check_license() then
                return fail(action, "License check failed")
            end
        end
    end
    -- clean work directory and special build depends (might also be delayed to just before program exit)
    local function port_clean()
        local function do_clean(origin)
            --TRACE("DO_CLEAN", origin)
            local must_clean = access(origin.wrkdir, "r")
            if must_clean then
                local need_root = not access(origin.wrkdir, "w") or not access(path_up(origin.wrkdir), "w")
                --TRACE("DO_CLEAN_AS", origin.name, need_root)
                return origin:port_make {
                    log = true,
                    jailed = true,
                    errtoout = true,
                    as_root = need_root,
                    "NO_CLEAN_DEPENDS=1",
                    "clean"
                }
            else
                return "", "", 0
            end
        end
        action:log {"Clean work directory of port", o_n.name}
        local out, _, exitcode = do_clean(o_n)
        if exitcode ~= 0 then
            return fail(action, "Failed to clean the work directory of " .. o_n.name, out)
        end
        for _, origin_target in ipairs(special_depends or {}) do
            --TRACE("PORT_CLEAN_SPECIAL_DEPENDS", o_n.name, origin_target)
            local target = target_part(origin_target)
            local origin = Origin:new(origin_target:gsub(":.*", ""))
            if target ~= "fetch" and target ~= "checksum" then
                action:log {"Clean work directory of special dependency", origin.name}
                out, _, exitcode = do_clean(origin)
                if exitcode ~= 0 then
                    return fail(action, "Failed to clean the work directory of " .. origin.port, out)
                end
            end
        end
    end
    local function special_deps()
        --TRACE("SPECIAL:", #special_depends, special_depends[1])
        if #special_depends > 0 then
            --TRACE("SPECIAL_DEPENDS", special_depends)
            -- local special_depends = action.pkg_new.origin.special_depends
            for _, origin_target in ipairs(special_depends) do
                -- print ("SPECIAL_DEPENDS", origin_target)
                local target = target_part(origin_target)
                local origin = Origin:new(origin_target:gsub(":.*", "")) -- define function to strip the target ???
                -- assert (origin:wait_checksum ())
                if target ~= "fetch" and target ~= "checksum" then
                    -- extract from package if $target=stage and _packages is set? <se>
                    local out, _, exitcode =
                        origin:port_make {
                        log = true,
                        jailed = true,
                        errtoout = true,
                        "NO_DEPENDS=1",
                        "DEFER_CONFLICTS_CHECK=1",
                        "DISABLE_CONFLICTS=1",
                        "FETCH_CMD=true",
                        target
                    }
                    if exitcode ~= 0 then
                        fail(action, "Failed to provide special dependency " .. origin_target, out)
                    end
                end
            end
        end
    end
    local function extract()
        local wrkdir_parent = path_up(o_n.wrkdir)
        action:log {"Extract port", portname}
        local _, _, exitcode =
            Exec.run {
            CMD.mkdir,
            "-p",
            wrkdir_parent
        }
        if exitcode ~= 0 then
            Exec.run {
                as_root = true,
                CMD.mkdir,
                "-p",
                wrkdir_parent
            }
            Exec.run {
                as_root = true,
                CMD.chown,
                Param.uid,
                wrkdir_parent
            }
        end
        local out, _, exitcode =
            o_n:port_make {
            log = true,
            errtoout = true,
            jailed = true,
            "NO_DEPENDS=1",
            "DEFER_CONFLICTS_CHECK=1",
            "DISABLE_CONFLICTS=1",
            "FETCH=true",
            "extract"
        }
        if exitcode ~= 0 then
            fail(action, "Build failed in extract phase", out)
        end
    end
    local function patch()
        action:log {"Patch port", portname}
        local out, _, exitcode =
            o_n:port_make {
            log = true,
            errtoout = true,
            jailed = true,
            "NO_DEPENDS=1",
            "DEFER_CONFLICTS_CHECK=1",
            "DISABLE_CONFLICTS=1",
            "FETCH=true",
            "patch"
        }
        if exitcode ~= 0 then
            fail(action, "Build failed in patch phase", out)
        end
    end
    local function configure()
        action:log {"Configure port", portname}
        local out, _, exitcode =
            o_n:port_make {
            log = true,
            errtoout = true,
            jailed = true,
            "NO_DEPENDS=1",
            "DEFER_CONFLICTS_CHECK=1",
            "DISABLE_CONFLICTS=1",
            "configure"
        }
        if exitcode ~= 0 then
            fail(action, "Build failed in configure phase", out)
        end
    end
    --[[
    local function conflicts()
        -- check whether build of new port is in conflict with currently installed version
        local deleted = {}
        local conflicts = check_build_conflicts (action)
        for i, pkg in ipairs (conflicts) do
            if pkg == pkgname_old then
                -- ??? pkgname_old is NOT DEFINED
                action:log{"Build of", portname, "conflicts with installed package", pkg .. ", deleting old package"}
                automatic = PkgDb.automatic_get (pkg)
                table.insert (deleted, pkg)
                perform_pkg_deinstall (pkg)
                break
            end
        end
    end
    --]]
    local function build()
        -- build port
        action:log {"Build port", portname}
        local out, _, exitcode =
            o_n:port_make {
            log = true,
            errtoout = true,
            jailed = true,
            "NO_DEPENDS=1",
            "DISABLE_CONFLICTS=1",
            "_OPTIONS_OK=1",
            "MAKE_JOBS_NUMBER_LIMIT=" .. tostring(action.jobs),
            "build"
        }
        if exitcode ~= 0 then
            fail(action, "Build failed in build phase", out)
        end
    end
    local function stage()
        --stage port
        action:log {"Install port", portname, "to staging area"}
        local out, _, exitcode =
            o_n:port_make {
            log = true,
            errtoout = true,
            jailed = true,
            "NO_DEPENDS=1",
            "DISABLE_CONFLICTS=1",
            "_OPTIONS_OK=1",
            "stage"
        }
        if exitcode ~= 0 then
            fail(action, "Build failed in stage phase", out)
        end
    end
    local function check_build_deps()
        for _, p in ipairs(build_dep_pkgs) do
            --TRACE("FAILED?", p)
            local a = ACTION_CACHE[p]
            if a and failed(a) then
                a.ignore = true
                return fail(action, "Skipped because of failed dependency " .. p)
            end
        end
    end
    local function preserve_old_shared_libraries()
        -- preserve currently installed shared libraries
        for _, p_o in ipairs(old_pkgs) do
            action:log {level = 2, "Preserve shared libraries of old version", p_o.name}
            if not p_o:shlibs_backup() then
                return fail(action, "Could not save old shared libraries to compat directory")
            end
        end
    end
    local function preserve_precious()
        -- preserve pkg-static even when deleting the "pkg" package
        if portname == "ports-mgmt/pkg" then
            Exec.run {
                as_root = true,
                CMD.ln,
                "-fF",
                CMD.pkg,
                CMD.pkg .. "~"
            }
        end
    end
    local function create_backup_packages()
        -- create backup package files from installed files
        for _, p_o in ipairs(old_pkgs) do
            local pkgname_old = p_o.name
            local create_backup = pkgname_old ~= pkgname_new or not pkgfile
            if create_backup then
                action:log {level = 1, "Create backup of old version", pkgname_old}
                local out, err, exitcode = p_o:backup_old_package()
                if exitcode ~= 0 then
                    return fail(action, "Create backup package for " .. pkgname_old, err)
                end
            end
        end
    end
    local function delete_old_packages()
        -- delete old package version
        for _, p_o in ipairs(old_pkgs) do
            action:log {level = 1, "Deinstall old version", p_o.name}
            local out, err, exitcode = p_o:deinstall()
--            register_deinstallation(p_o, exitcode == 0) -- allow automatic packages to be deleted after last dependency is gone
            if exitcode ~= 0 then
                -- XXX try to recover from failed deinstallation - reinstall backup package?
                fail(action, "Failed to deinstall old version", err)
            end
        end
    end
    local function recover_precious()
        -- restore pkg-static if it has been preserved
        if portname == "ports-mgmt/pkg" then
            Exec.run {
                as_root = true,
                CMD.mv,
                "-fF",
                CMD.pkg .. "~",
                CMD.pkg
            }
        end
    end
    local function install_from_package()
        -- try to install from package
        --TRACE("PERFORM_INSTALLATION/PKGFILE", p_n.pkgfile)
        action:log {"Install from package file", p_n.pkgfile}
        -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
        local _, err, exitcode = p_n:install()
        local errtxt
        if exitcode ~= 0 then
            p_n:deinstall() -- ignore output and exitcode
            if not Options.jailed then
                for _, p_o in ipairs(old_pkgs) do
                    _, err, exitcode = p_o:recover()
                    if exitcode ~= 0 then
                        errtxt = err
                    end
                end
            end
            --[[ rename only if failure was not due to a conflict with an installed package!!!
            {"Rename", pkgfile, "to", pkgfile .. ".NOTOK after failed installation")
            os.rename(pkgfile, pkgfile .. ".NOTOK")
            --]]
            fail(action, "Failed to install from package file " .. p_n.pkgfile, err)
            if errtxt then
                fail(action, "Could not re-install previously installed version after failed installation", errtxt)
            end
        end
    end
    local function install_from_stage_area()
        -- try to install new port
        --TRACE("PERFORM_INSTALLATION/PORT", portname)
        -- >>>> PkgDbLock(weight = 1)
        -- PkgDb.lock() -- only one installation at a time due to exclusive lock on pkgdb
        action:log {"Install", pkgname_new, "built from", portname, "on base system"}
        local out, err, exitcode = o_n:install() -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
        --PkgDb.unlock()
        -- <<<< PkgDbLock(weight = 1)
        if exitcode ~= 0 then
            local errtxt
            deinstall_failed_port(action)
            for _, p_o in ipairs(old_pkgs) do
                local out, err, exitcode = p_o:recover()
                if exitcode ~= 0 then
                    errtxt = err
                end
            end
            fail(action, "Failed to install port " .. portname, err)
            if errtxt then
                return fail(action, "Could not re-install previously installed version after failed installation", errtxt)
            end
        end
    end
    -- perform actual installation from a port or package
    local function post_install_fixup()
        --TRACE("PERFORM_INSTALLATION", action)
        -- set automatic flag to the value the previous version had
        if action.is_auto then
            p_n:automatic_set(true)
        end
    end
    local function cleanup_old_shared_libraries()
        -- remove all shared libraries replaced by new versions from shlib backup directory
        for _, p_o in ipairs (old_pkgs) do
            p_o:shlibs_backup_remove_stale() -- use action as argument???
        end
    end
    local function delete_stale_pkgfiles()
        -- delete stale package files
        for _, p_o in ipairs(old_pkgs) do
            local pkgname_old = p_o.name
            if pkgname_old ~= pkgname_new then
                p_o:delete_old()
                if not Options.backup then
                    p_o:backup_delete()
                end
            end
        end
    end
    local function build_step(step)
        if not failed(action) then
            step(action)
        end
    end
    local function build_done(step)
        if not failed(action) then
            action.buildstate[step] = true
            --TRACE("BUILDSTATE", action.pkg_new.name, step)
        end
    end

    TRACE("PERFORM_INSTALL_OR_UPGRADE", action)
    -- has a package been identified to be used instead of building the port?
    TRACE("BUILDREQUIRED", action.do_build, action.force, Options.packages)
    action.buildstate = {}
    if action.do_build then
        -- == do_build==true if the port has to be built (independently of whether and where it will be installed)
        -- == i.e. we are not installing from a package file ...
        WorkDirLock = WorkDirLock or Lock:new("WorkDirLock")
        -- >>>> WorkDirLock(o_n.wrkdir)
        WorkDirLock:acquire {tag = p_n.name, o_n.wrkdir} -- XXX adjust condition to that of the corresponding release() !!!
        --TRACE("perform_portbuild", portname, pkgname_new, special_depends)
        -- >>>> RunnableLock(build_dep_pkgs, SHARED)
        --build_dep_pkgs = pkgs_from_origin_tables(build_depends, special_depends)
        build_dep_pkgs = action.depends.build
        build_dep_pkgs.shared = true
        build_dep_pkgs.tag = pkgname_new
        RunnableLock:acquire(build_dep_pkgs) -- acquire shared lock to wait for build deps to become runnable
        build_step(check_build_deps)
        build_step(wait_for_distfiles)
        JobsLock = JobsLock or Lock:new("JobsLock", Param.maxjobs) -- limit number of processes to one per (virtual) core
        -- >>>> JobsLock(weight = action.jobs)
        JobsLock:acquire({weight = action.jobs})
        if not Options.no_pre_clean then
            -- == no_pre_clean==true if work directory shall be used without cleaning
            build_step(port_clean)
        end
        build_step(check_license)
        build_step(special_deps)
        build_step(extract)
        build_step(patch)
        --build_step(conflicts)
        build_step(configure)
        build_step(build)
        JobsLock:release({weight = action.jobs})
        -- <<<< JobsLock(weight = action.jobs)
        build_step(stage)
        RunnableLock:release(build_dep_pkgs)
        if Options.create_package then
            -- == create_package==true to create a new package from a port
            -- >>>> RunnableLock(action.depends.pkg)
            RunnableLock:acquire(action.depends.pkg)
            TRACE("RUNNABLE_LOCK_ACQUIRE_SHARED2", table.concat(action.depends.pkg or {}, " "), RunnableLock)
            build_step(package_create)
            RunnableLock:release(action.depends.pkg)
            -- <<<< RunnableLock(action.depends.pkg)
            build_done("package") -- XXX set if no package is to be created, too ???
        end
    end
    -- install build depends immediately but optionally delay installation of other ports
    if not action.skip_install then
        -- == skip_install==true if the port or pkgfile will not be immediately installed in the build jail (or base system)
        TRACE("DEPENDS:", action.short_name, action.depends)
        -- >>>> RunnableLock(action.depends.pkg)
        RunnableLock:acquire(action.depends.pkg)
        TRACE("RUNNABLE_LOCK_ACQUIRE_SHARED3", table.concat(action.depends.pkg or {}, " "), RunnableLock)
        -- prepare installation, if this is an upgrade (and not a fresh install)
        if #old_pkgs > 0 then
            -- == #old_pkgs>0 if old packages need to be de-intalled before the new port can be installed to the base system
            -- == this cannot happen in the jail where no old packages exist
            --TRACE("PERFORM_INSTALLATION/REMOVE_OLD_PKG", old_pkgs)
            if not Options.jailed or Param.phase == "install" then
                -- == true, if installation on the base system has to be prepared
                -- >>>> RunnableLock(action.depends.pkg)
                RunnableLock:acquire(action.depends.pkg)
                TRACE("RUNNABLE_LOCK_ACQUIRE_SHARED3", table.concat(action.depends.pkg or {}, " "), RunnableLock)
                build_step(create_backup_packages)
                if Options.save_shared then
                    -- == if save_shared==true then preserve old shared libraries in compat directory
                    build_step(preserve_old_shared_libraries)
                end
                build_step(preserve_precious)
                build_step(delete_old_packages) -- PKGS!!!
                build_step(recover_precious)
                RunnableLock:release(action.depends.pkg)
                -- <<<< RunnableLock(action.depends.pkg)
            end
        end
        if action.do_provide or action.do_install then
            -- == true if port or package is to be immediately installed into the build jail or on the base system
            if action.do_build then
                -- == true if port has been built and staged
                -- >>>> RunnableLock(action.depends.pkg)
                RunnableLock:acquire(action.depends.pkg)
                TRACE("RUNNABLE_LOCK_ACQUIRE_SHARED3", table.concat(action.depends.pkg or {}, " "), RunnableLock)
                build_step(install_from_stage_area)
                RunnableLock:release(action.depends.pkg)
                -- <<<< RunnableLock(action.depends.pkg)
                -- preserve file names and hashes of distfiles from new port
                -- NYI distinfo_cache_update (o_n, pkgname_new)
                -- backup clean port directory and special build depends (might also be delayed to just before program exit)
                if not Options.no_post_clean then
                    -- == if no_post_clean==false then clean work directory (including possible special_depend workdirs)
                    build_step(port_clean)
                    -- delete old distfiles
                    -- NYI distfiles_delete_old (o_n, pkgname_old) -- OUTPUT
                end
                WorkDirLock:release {o_n.wrkdir}
                -- <<<< WorkDirLock(o_n.wrkdir)
            else
                -- == execute if no port has been built and installation from a package is required
                -- >>>> RunnableLock(action.depends.pkg)
                RunnableLock:acquire(action.depends.pkg)
                TRACE("RUNNABLE_LOCK_ACQUIRE_SHARED4", table.concat(action.depends.pkg or {}, " "), RunnableLock)
                build_step(install_from_package)
                RunnableLock:release(action.depends.pkg)
                -- <<<< RunnableLock(action.depends.pkg)
            end
            build_step(post_install_fixup)
            build_step(delete_stale_pkgfiles)
            if Options.save_shared then
                -- == if old shared libraries may have been saved in the compat directory then delete those that have been installed anew
                build_step(cleanup_old_shared_libraries)
            end
            -- >>>> RunnableLock(action.depends.run)
            RunnableLock:acquire(action.depends.run)
            TRACE("RUNNABLE_LOCK_RELEASE", p_n.name)
            RunnableLock:release{p_n.name}
            -- <<<< RunnableLock(p_n.name)
            --build_step(fetch_pkg_message)
            build_done("provide")
            if not Options.jailed then
                -- == if jailed then the installation to the base system has not been peformed yet
                build_done("install")
            end
        end
    end
    -- report success or failure ...
    if not Options.dry_run then
        local failed_msg, failed_log = failed(action)
        if failed_msg then
            action:log {describe(action), "FAILURE:", failed_msg .. (failed_log and ":" or "")}
            if failed_log then
                Msg.show {verbatim = true, failed_log, "\n"}
            end
        else
            action:log {"SUCCESS:", describe(action)}
        end
    end
    return not failed(action)
end

-------------------------------------------------------------------------------------
local function perform_upgrades(action_list)
    -- install or upgrade required packages
    for _, action in ipairs(action_list) do
        -- if Options.hide_build is set the buildlog will only be shown on errors
        local p_n = action.pkg_new
        local o_n = p_n and p_n.origin
        local is_interactive = o_n and o_n.is_interactive
        if Options.hide_build and not is_interactive then
        -- set to_tty = false for shell commands
        --BUILDLOG = tempfile_create("BUILD_LOG")
        end
        if action.ignore then
            --TRACE("IGNORE". action.describe)
        --elseif -- change origin and rename port here ...
        --        perform_origin_change(action)
        else
            Exec.spawn(perform_install_or_upgrade, action)
        end
    end
    Exec.finish_spawned()
    return true
end

-- update repository database after creation of new packages
local function perform_repo_update()
    Msg.show {start = true, "Create local package repository database ..."}
    PkgDb.update_repo()
end

--[[
-- perform delayed installations unless only the repository should be updated
local function perform_delayed_installations()
    -- NYI
end
--]]
-- ask user whether to delete packages that have been installed as dependency and are no longer required
local function packages_delete_stale()
    local pkgnames_list = PkgDb.list_pkgnames("%a==1 && %#r==0")
    for _, l in ipairs(pkgnames_list) do
        if l then
            for _, pkgname in ipairs(l) do
                if Msg.read_yn("y", "Package", pkgname, "was installed as a dependency and does not seem to be used anymore, delete") then
                    Package.deinstall(pkgname)
                elseif Msg.read_yn("y", "Mark", pkgname, "as 'user installed' to protect it against automatic deletion") then
                    PkgDb.automatic_set(pkgname, false)
                end
            end
        end
    end
end

-- display statistics of actions to be performed
local function show_statistics(action_list)
    -- create statistics line from parameters
    local NUM = {}
    local function format_install_msg(num, actiontext)
        if num and num > 0 then
            local plural_s = num ~= 1 and "s" or ""
            return string.format("%5d %s%s %s", num, "package", plural_s, actiontext)
        end
    end
    local function count_actions()
        local function incr(field)
            NUM[field] = (NUM[field] or 0) + 1
        end
        for _, v in ipairs(action_list) do
            if action_is(v, "upgrade") then
                local old_pkgs = v.old_pkgs
                local p_n = v.pkg_new
                if #old_pkgs == 1 and old_pkgs[1] == p_n then
                    incr("reinstalls")
                elseif #old_pkgs == 0 then
                    incr("installs")
                else
                    incr("upgrades")
                end
            elseif action_is(v, "delete") then
                incr("deletes")
            elseif action_is(v, "change") then
                incr("moves")
            end
        end
    end
    local num_tasks
    local installed_txt, reinstalled_txt
    if not Options.repo_mode then
        installed_txt = "installed"
        reinstalled_txt = "re-installed"
    else
        installed_txt = "added"
        reinstalled_txt = "rebuilt"
    end
    num_tasks = tasks_count()
    if num_tasks > 0 then
        count_actions(action_list)
        Msg.show {start = true, "Statistic of planned actions:"}
        local txt = format_install_msg(NUM.deletes, "will be deleted")
        if txt then
            Msg.show {txt}
        end
        txt = format_install_msg(NUM.moves, "will be changed in the package registry")
        if txt then
            Msg.show {txt}
        end
        -- Msg.cont (0, format_install_msg (NUM.provides, "will be loaded as build dependencies"))
        -- if txt then Msg.cont (0, txt) end
        -- Msg.cont (0, format_install_msg (NUM.builds, "will be built"))
        -- if txt then Msg.cont (0, txt) end
        txt = format_install_msg(NUM.reinstalls, "will be " .. reinstalled_txt)
        if txt then
            Msg.show {txt}
        end
        txt = format_install_msg(NUM.installs, "will be " .. installed_txt)
        if txt then
            Msg.show {txt}
        end
        txt = format_install_msg(NUM.upgrades, "will be upgraded")
        if txt then
            Msg.show {txt}
        end
        Msg.show {start = true}
    end
end

--
local function determine_pkg_old(action, k)
    local pt = action.o_o and action.o_o.old_pkgs -- XXX support multiple old packages in action !!!
    if pt then
        local pkg_new = action.pkg_new
        if pkg_new then
            local pkgnamebase = pkg_new.name_base
            for p, _ in ipairs(pt) do
                if p.name_base == pkgnamebase then
                    return p
                end
            end
        end
    end
end

-- XXX conflicts check required???
local function determine_pkg_new(action, k)
    TRACE("DETERMINE_PKG_NEW", action)
    local p_n
    for _, p_o in ipairs(action.old_pkgs or {}) do
        local o_o = p_o.origin
        TRACE("DETERMINE_PKG_NEW(o_o)-1", o_o)
        if o_o and o_o.port_exists then
            p_n = o_o.pkg_new
            TRACE("DETERMINE_PKG_NEW(o_o)-1.1", o_o.name, p_o.name_base, p_n and p_n.name_base)
            if p_n and p_n.name_base == p_o.name_base then
                TRACE("DETERMINE_PKG_NEW->", p_n.name)
                return p_n
            end
        end
    end
    local pkgs = {}
    for _, p_o in ipairs(action.old_pkgs or {}) do
        local o_o = p_o.origin
        TRACE("DETERMINE_PKG_NEW(o_o)-2", o_o)
        local o_n = o_o and Moved.new_origin(o_o)
        if o_n and o_n.port_exists then
            p_n = o_n.pkg_new
            if p_n then
                local basename = p_n.name_base
                for _, p_o in ipairs(action.old_pkgs) do
                    if p_o.name_base == basename then
                        TRACE("DETERMINE_PKG_NEW->", p_n.name)
                        return p_n
                    end
                end
            end
        end
    end
    TRACE("DETERMINE_PKG_NEW->", p_n and p_n.name or "<nil>")
    return p_n
end

local function determine_origin_old(action, k)
    local p_n = action.pkg_new
    if p_n then
        local basename = p_n.name_base_major
        local o_n = p_n.origin
        for _, pkgname in ipairs(o_n.old_pkgs) do
            local p_o = Package.get(pkgname)
            if p_o and p_o.name_base_major == basename then
                action.pkg_old = p_o
            end
        end
        basename = p_n.name_base
        for _, pkgname in ipairs(o_n.old_pkgs) do
            local p_o = Package.get(pkgname)
            if p_o and p_o.name_base == basename then
                action.pkg_old = p_o
            end
        end
    end
end

--
local function determine_o_o(action, k)
    -- print ("OO:", action.pkg_old, (rawget (action, "pkg_old") and (action.pkg_old).origin or "-"), action.pkg_new, (rawget (action, "pkg_new") and (action.pkg_new.origin or "-")))
    local old_pkgs = action.old_pkgs -- XXX support more than 1 old package !!!
    local p_o = old_pkgs[1] -- should be tested in a loop !!! XXX
    local o = p_o and rawget(p_o, "origin") or action.pkg_new and action.pkg_new.origin -- XXX NOT EXACT
    return o
end

--
local function determine_o_n(action, k)
    for p_o in ipairs(action.old_pkgs) do
        local o_o = p_o.origin
        if o_o then
            local o_n = Moved.new_origin(o_o)
            if o_n and o_n.exists then
                return o_n
            end
            if not o_o.reason and o_o.exists then
                return o_o
            end
        end
    end
end

--
local function compare_versions_old_new(action)
    local old_pkgs = action.old_pkgs
    local p_n = action.pkg_new
    if p_n then
        local n = p_n.name_base
        local f = p_n.origin and p_n.origin.flavor
        for _, p_o in ipairs(old_pkgs) do
            if p_o.name_base == n then
                if p_n.origin and f ~= p_n.origin.flavor then
                    return -1 -- flavor mismatch requires update
                end
                return Package.compare_versions(p_o, p_n)
            end
        end
    end
    return -1 -- return outdated if the base names did not match
end

--
local function determine_action(action, k)
    if action.is_locked then
        action_set(action, "exclude")
    elseif action.do_deinstall then
        action_set(action, "delete")
    elseif #action.old_pkgs == 0 or action.do_upgrade then
        action_set(action, "upgrade")
    --[[
    elseif p_o ~= p_n or origin_changed(o_o, o_n) then
        action_set(action, "change")
    --]]
    else
        action_set(action, "keep")
    end
    return action.action
end

--
local function check_config_allow(action, recursive)
    --TRACE("CHECK_CONFIG_ALLOW", action.pkg_new and action.pkg_new.name, recursive)
    if not action.pkg_new then
        return
    end
    local origin = action.pkg_new.origin
    local function check_ignore(name, field)
        --TRACE("CHECK_IGNORE", origin.name, name, field, rawget(origin, field))
        if rawget(origin, field) then
            fail(action, "Is marked " .. name .. " and will be skipped: " .. origin[field] .. "\n" .. "If you are sure you can build this port, remove the " .. name .. " line in the Makefile and try again")
        end
    end
    -- optionally or forcefully configure port
    local function configure(origin, force)
        local target = force and "config" or "config-conditional"
        return origin:port_make {
            to_tty = true,
            as_root = Param.port_dbdir_ro,
            "-DNO_DEPENDS",
            "-DDISABLE_CONFLICTS",
            target
        }
    end
    check_ignore("BROKEN", "is_broken")
    check_ignore("IGNORE", "is_ignore")
    if Options.no_make_config then
        check_ignore("FORBIDDEN", "is_forbidden")
    end
    if not recursive then
        local do_config
        if origin.is_forbidden then
            Msg.show {origin.name, "is marked FORBIDDEN:", origin.is_forbidden}
            if origin.all_options then
                Msg.show {"You may try to change the port options to allow this port to build"}
                Msg.show {}
                if Msg.read_yn("y", "Do you want to try again with changed port options") then
                    do_config = true
                end
            end
        elseif origin.new_options or Options.force_config then
            do_config = true
        elseif origin.port_options and origin.options_file and not access(origin.options_file, "r") then
            --TRACE("NO_OPTIONS_FILE", origin)
        -- do_config = true
        end
        if do_config then
            --TRACE("NEW_OPTIONS", origin.new_options)
            configure(origin, recursive)
            return false
        end
    end
    -- ask for confirmation if requested by a program option
    if Options.interactive then
        if not Msg.read_yn("y", "Perform upgrade") then
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

--
local function check_licenses()
    --local accepted = {}
    --local accepted_opt = nil
    local function check_accepted(licenses)
        --
    end
    local function set_accepted(licenses)
        -- LICENSES_ACCEPTED="L1 L2 L3"
    end
    for _, action in ipairs(ACTION_LIST) do
        local o = rawget(action.pkg_new, "origin")
        if o and rawget(o, "license") then
            if not check_accepted(o.license) then
                action:log {"Check license for", o.name, o.license}
                -- o:port_make {"-DDEFER_CONFLICTS_CHECK", "-DDISABLE_CONFLICTS", "extract", "ask-license", accepted_opt}
                -- o:port_make {"clean"}
                set_accepted(o.license)
            end
        end
    end
end

--
local function check_conflicts(mode)
    Msg.show {level = 2, start = true, "Check for conflicts between requested updates and installed packages"}
    for _, action in ipairs(ACTION_LIST) do
        local p_n = action.pkg_new
        local o_n = rawget(p_n, "origin")
        if o_n and o_n[mode] then
            local conflicts_table = conflicting_pkgs(action, mode)
            if conflicts_table and #conflicts_table > 0 then
                local text = ""
                for _, pkg in ipairs(conflicts_table) do
                    text = text .. " " .. pkg.name
                end
                Msg.show {"Conflicting packages for", o_n.name, text}
            end
        end
    end
    Msg.show {level = 2, start = true, "Check for conflicts has been completed"}
end

--
local function check_excluded(action)
    local function locked_pkg(pkg)
        if pkg then
            return pkg.is_locked, pkg.name, "package is locked"
        end
    end
    local function excluded_pkg(pkg)
        if pkg then
            if Excludes.check_pkg(pkg) then
                return true, pkg.name, "excluded on user request"
            end
        end
    end
    local function ignored_port(origin)
        if origin then
            if origin.is_forbidden then
                return true, origin.name, origin.is_forbidden
            end
            if origin.is_broken and not Param.try_broken then
                return true, origin.name, origin.is_broken
            end
            if origin.is_ignore then
                return true, origin.name, origin.is_ignore
            end
            if Excludes.check_port(origin) then
                return true, origin.name, "excluded on user request"
            end
        end
    end
    local function excluded_chk(f, arg)
        if not rawget (action, "ignore") then
            local excluded, name, reason = f(arg)
            if excluded then
                action.ignore = true
                fail(action, name .. " " .. reason)
            end
        end
    end
    local old_pkgs = action.old_pkgs
    local o_n = action.pkg_new and action.pkg_new.origin
    excluded_chk(ignored_port, o_n)
    for _, p_o in ipairs(old_pkgs) do
        excluded_chk(ignored_port, p_o.origin)
    end
    excluded_chk(excluded_pkg, action.pkg_new)
    for _, p_o in ipairs(old_pkgs) do
        excluded_chk(excluded_pkg, p_o)
    end
    excluded_chk(locked_pkg, action.pkg_new)
    for _, p_o in ipairs(old_pkgs) do
        excluded_chk(locked_pkg, p_o)
    end
    return rawget(action, "ignore")
end

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache()
    local t = ACTION_CACHE
    for _, v in ipairs(table.keys(t)) do
        --TRACE("ACTION_CACHE", v, t[v])
    end
end

-------------------------------------------------------------------------------------
--[[
local function __newindex(action, n, v)
    --TRACE("SET(a)", rawget(action, "pkg_new") and action.pkg_new.name or rawget(action, "pkg_old") and action.pkg_old.name, n, v)
    if v and (n == "pkg_old" or n == "pkg_new") then
        ACTION_CACHE[v.name] = action
    end
    rawset(action, n, v)
end
--]]

local actions_started = 0

local function __index(action, k)
    local function __short_name(action, k)
        TRACE("T", action)
        local p_n = action.pkg_new
        local o_n = p_n and p_n.origin
        local old_pkgs = action.old_pkgs
        action.short_name = p_n and p_n.name
            or o_n and o_n.name
            or #old_pkgs > 0 and old_pkgs[1].name
            or "<unknown>"
        TRACE("T->", action.short_name)
        return action.short_name
    end
    local function __startno(action, k)
        actions_started = actions_started + 1
        return actions_started -- action.listpos
    end
    local function __jobs(action, k)
        local p_n = action.pkg_new
        if p_n.no_build or p_n.make_jobs_unsafe or p_n.disable_make_jobs then
            return 1
        end
        local n = p_n.make_jobs_number or Param.maxjobs
        local limit = p_n.make_jobs_number_limit or Param.ncpu
        if n > limit then
            n = limit
        end
        return math.floor(n) -- convert from float to integer
    end
    local function __depends(action, k)
        local p_n = action.pkg_new
        if p_n then
            return p_n.depends
        else
            return {}
        end
    end
    local function __check_req_for(action, k)
        local depends = action.depends
        return {
            build = #depends.build > 0,
            build_only = #depends.build > 0 and #depends.run == 0 and #depends.pkg == 0,
            pkg = #depends.pkg > 0,
            run = #depends.run > 0,
        }
    end
    local function __use_pkgfile(action, k)
        --TRACE("USE_PKGFILE?", action)
        local p_n = action.pkg_new
        if p_n then
            if action.force then -- always rebuild if forced
                --TRACE("NOT USE_PKGFILE", "force", p_n.name)
                return false
            end
            if not p_n.pkgfile then -- no usable package file found
                --TRACE("NOT USE_PKGFILE", "no pkgfile", p_n.name)
                return false
            end
            if Options.packages then -- use package if allowed and available
                --TRACE("USE_PKGFILE", "use pkgfile", p_n.name)
                return true
            end
            if action.req_for.run or not action.is_auto then -- build from port if not only a build dependency
                --TRACE("NOT USE_PKGFILE", "user installed or run dependency without --packages option", p_n.name)
                return false
            end
            if Options.packages_build then -- rebuild pure build dependencies unless pkg allowed
                --TRACE("USE_PKGFILE", "build dep from pkgfile allowed", p_n.name)
                return true
            end
            --TRACE("NOT USE_PKGFILE", "no --packages-build option", p_n.name)
        end
    end
    local function __is_auto(action, k) -- force is_auto to false for new user installed packages!!! XXX
        for _, p_o in ipairs(action.old_pkgs) do
            if not rawget(p_o, "is_automatic") then
                return false
            end
        end
        return true
    end
    local function __check_upgrade_needed(action, k)
        return action.force or compare_versions_old_new(action) ~= 0
    end
    local function __check_build_needed(action, k)
        return action.pkg_new and not action.use_pkgfile
    end
    local function __check_provide_needed(action, k)
        if Param.jailed and action.pkg_new then
            local req_for = action.req_for
            return req_for.build or req_for.run -- XXX NYI
        end
    end
    local function __check_install_needed(action, k)
        return action.pkg_new and (Param.jailed and action.req_for.build or not action.req_for.build_only) -- XXX NYI
    end
    local function __check_pkgcreate_needed(action, k)
        return true -- XXX NYI
    end
    local function __check_deinstall_requested(action, k)
        return not action.pkg_new
    end
    local function __check_forced(action, k)
        return action.force -- XXX NYI
    end
    local function __check_skip_install(action, k) -- do not install to base system
        TRACE("X", action)
        if Options.skip_install or Options.jailed then
            if action.is_auto then
                local req_for = action.req_for
                return not req_for.build and not req_for.pkg
            end
        end
    end
    local function __check_locked(action, k)
        local p_n = action.pkg_new
        if p_n and p_n.is_locked then
            return true
        end
        for _, p_o in ipairs(action.old_pkgs) do
            if p_o.is_locked then
                return true -- ADD FURTHER CASES: excluded, broken without --try-broken, ignore, ...
            end
        end
    end
    local dispatch = {
        name = describe,
        short_name = __short_name,
        pkg_new = determine_pkg_new,
        pkg_old = determine_pkg_old,
        vers_cmp = compare_versions_old_new,
        action = determine_action,
        startno = __startno,
        jobs = __jobs,
        ignore = check_excluded,
        depends = __depends,
        req_for = __check_req_for,
        --is_special_pkg = __check_dep,
        is_auto = __is_auto,
        is_locked = __check_locked,
        use_pkgfile = __use_pkgfile,
        skip_install = __check_skip_install,
        do_upgrade = __check_upgrade_needed,
        do_build = __check_build_needed,
        do_provide = __check_provide_needed,
        do_install = __check_install_needed,
        do_pkgcreate = __check_pkgcreate_needed,
        do_deinstall = __check_deinstall_requested,
        force = __check_forced,
    }

    --TRACE("INDEX(a)", k)
    local w = rawget(action.__class, k)
    if w == nil then
        local f = dispatch[k]
        if f then
            rawset(action, k, false)
            w = f(action, k)
            if w then
                rawset(action, k, w)
            end
        else
            error("illegal field requested: Action." .. k)
        end
        --TRACE("INDEX(a)->", k, w)
    else
        --TRACE("INDEX(a)->", k, w, "(cached)")
    end
    return w
end

local mt = {
    __index = __index,
    --__newindex = __newindex, -- DEBUGGING ONLY
    __tostring = describe
}

--[[
    -- user flag is implied by missing auto flag
    user/run = user requested installation on base system
    user/build = -- illegal --
    auto/run = run time dependency to be installed on base system
    auto/build = build dependency to be provided in build environment (jail or base)
    build/build = build dependency of build dependency
    build/run = run dependency of build dependency
--]]

--
local function action_list_add(action)
    TRACE("LIST_ADD_ACTION", action)
    local old_pkgs = action.old_pkgs
    local p_n = action.pkg_new
    if p_n or #old_pkgs > 0 then
        TRACE("IGNORE?", action.short_name, action.ignore)
        if not action.ignore then
            if action.do_upgrade or action.do_provide then
                local listpos = rawget(action, "listpos")
                if not listpos then
                    if not action.skip_install and (action.do_provide or action.do_install) then
                        RunnableLock = RunnableLock or Lock:new("RunnableLock") -- XXX dead-lock due to double locking !!!
                        -- >>>> RunnableLock(p_n.name)
                        RunnableLock:acquire{p_n.name} -- acquire exclusive lock until package is runnable
                        TRACE("RUNNABLE_LOCK_ACQUIRE", p_n.name)
                    end
                    listpos = #ACTION_LIST + 1
                    action.listpos = listpos
                    Msg.show {listpos, describe(action)}
                end
                TRACE("ACTION_LIST_ADD", action.listpos, action.short_name)
                ACTION_LIST[listpos] = action
            end
        end
    else
        -- error: action_list_add() called without old or new package
    end
end

-- add action as new or merge into existing action
--[[
    possible action record fields:
    * upgrade of existing package:
        may be for all installed packages or some ports or packages specified on the command line
        old_pkgs[1] contains the existing package, the origin is set as registered in the package db
    * dependency of existing package:
        pkg_new contains the package record, the origin is set to the current origin of the port
        the old package(s) needs to be identified (same origin, or origin lookup in MOVED)
        this can be a new installation or an upgrade (but only if not all outdated packages have been selected to be updated)
        if this a dependency is locked, the existing package shall be kept (may lead to a build failure in the dependent package)
        if this is a new pacakge, its "automatic" flag will be set
    * new installation:
        the origin has been passed on the command line, PKGNAME can be identified from the port
        this will be a new installation (user selected, not as an automatic dependency)
--]]
local function cache_add(action)
    local function cache_lookup(action)
        local p_n = action.pkg_new
        local action0 = p_n and ACTION_CACHE[p_n.name]
        if not action0 then
            local old_pkgs = action.old_pkgs
            if #old_pkgs > 0 then
                for _, p_o in ipairs(old_pkgs) do
                    action0 = ACTION_CACHE[p_o.name]
                    if action0 then
                        break
                    end
                end
            end
        end
        return action0
    end
    local p_n = action.pkg_new
    local action0 = cache_lookup(action)
    TRACE("CACHE_ADD", p_n and p_n.name, rawget(action, "name"), rawget(action, "listpos"), action0 and rawget(action0, "name"), action0 and rawget(action0, "listpos"))
    -- if #action.old_pkgs == 0 then this is a dependency / upgrade only if action record already exists
    if action0 then
        if rawget(action0, "listpos") then
            action, action0 = action0, action -- update the existing action record
        end
        TRACE("CACHE_ADD_MERGE", action.pkg_new and action.pkg_new.name, rawget(action, "listpos"), action0.pkg_new.name, rawget(action0, "listpos"))
        action.old_pkgs = table.union(action.old_pkgs, action0.old_pkgs)
        -- merge force, req_for[], is_user, ... ??? XXX
    else
        local p_n = action.pkg_new
        TRACE("CACHE_ADD_NEW", action.short_name, p_n, rawget(action, "listpos"))
        if p_n then
            ACTION_CACHE[p_n.name] = action
        end
        for _, p_o in ipairs(action.old_pkgs) do
            ACTION_CACHE[p_o.name] = action
        end
    end
    --[[
    if #action.old_pkgs == 0 then
        -- TRY TO IDENTIFY OLD PACKAGE / ORIGIN
        determine_origin_old(action)
    end
    --]]
    check_config_allow(action)
    TRACE("LIST_ADD", action.pkg_new and action.pkg_new.name or action.old_pkgs[1].name, rawget(action, "listpos"))
    action_list_add(action)
end

-- object that controls the upgrading and other changes
local function new(Action, args)
    if args then
        TRACE("ACTION", args)
        args.old_pkgs = {args.pkg_old}
        args.pkg_old = nil
        local action = args
        action.__class = Action
        action.buildstate = {}
        setmetatable(action, mt)
        TRACE("ACTION(new)->", action)
        cache_add(action)
    else
        error("Action:new() called with nil argument")
    end
end

-------------------------------------------------------------------------------------
--
return {
    new = new,
    get = get,
    describe = describe,
    --execute = execute,
    packages_delete_stale = packages_delete_stale,
    -- register_delayed_installs = register_delayed_installs,
    --sort_list = sort_list,
    check_licenses = check_licenses,
    check_conflicts = check_conflicts,
    --port_options = port_options,
    dump_cache = dump_cache,
    list = list,
    tasks_count = tasks_count,
    show_statistics = show_statistics,
    perform_upgrades = perform_upgrades,
    log = log,
}

--[[
   Instance variables of class Action:
   - action = operation to be performed
   - origin = origin object (for port to be built)
   - o_o = optional object (for installed port)
   - old_pkg = installed package object
   - new_pkg = new package object
   - done = status flag
--]]

--[[
Missing:
- strategy for resolution of conflicts
- non-flavored ports that create different packages (e.g. selected by default version settings)
- update decisions, were a package is to be replaced by a new version that corresponds to some other installed package - e.g. lua52-posix -> lua53-posix when an older package of lua53-posix is already installed

-- there are ports that depend on DEFAULT_VERSIONS instead of FLAVOR without indication in the package name!
-- the DEFAULT_VERSIONS value is required in port_make (origin), but it depends not on the origin, but the action !!!)

-- the -o option allows to switch origins for installed ports
--]]

--[[
For updates of existing ports:

   - pkg_old and o_o can be retrieved from the pkgdb

For updates of selected ports:

   - port or package names may be given
   - port names should include a flavor, if applicable (and if not the default flavor)
   - package names may be given without version number

For the installation of new ports:

   - port names must be provided
   - port names should include a flavor, if applicable (and if not the default flavor)
--]]

--[[
Possible port/package name conversions:

   o_o (pkg_old)
   - for installed packages always possible via pkgdb
   - implementation via PACKAGES_CACHE[pkg_old.name].origin
   - if applicable: DEFAULT_VERSIONS parameter can be derived from the old package name (string match)

   o_n (o_o, pkg_old)
   - in general same as o_o, but must be verified!!!
   - !!! lookup in MOVED port list (not fully deterministic due to lack of a "flavors required" flag in the list)
   - conflicts check required (via pkg_new (o_n)) to verify acceptable origin has been found

   pkg_old (pkg_new)
   - in general the old name can be found by looking up the package name without version in the pkgdb
   - the lookup is not guaranteed to succeed due to package name changes (e.g. if FLAVORS have been added or removed from a port)

   pkg_old (o_o, pkg_new)
   - for installed packages always possible via pkgdb lookup of origin with flavor
   - implementation via ORIGIN_CACHE[o_o.name].old_pkgs
   - !!! possibly multiple results (due to multiple packages built with different DEFAULT_VERSIONS settings)
   - pkg_new may be used to select the correct result if multiple candidate results have been obtained

   pkg_new (o_n, pkg_old)
   - from make -V PKGNAME with FLAVOR and possibly DEFAULT_VERIONS override (must be derived from pkg_old !!!)
   - might depend on port OPTIONS
   - conflicts check required !!!

   o_o (o_n, pkg_new)
   - lookup via pkg_new (without version) may be possible, but pkg_new may depend on parameters derived from pkg_old (DEFAULT_VERSIONS)
   - reverse lookup in the MOVED list until an entry in the pkgdb matches
   - the old origin might have been the same as the provided new origin (and in general will be ...)


Conflicts:

   - conflict of upgrade with port dependency of new origin - in general, upgrade should have priority
   - conflict of upgrade with installed file - installed file should probably have priority
   - derived pkg_new might be for a different DEFAULT_VERSION if the correct pkg_old has not been recognized

--]]


--[[
-- delete build dependencies after dependent ports have been built
local function perform_post_build_deletes(origin)
    local origins = DEP_DEL_AFTER_BUILD[origin.name]
    DEP_DEL_AFTER_BUILD[origin.name] = nil
    local del_done = false
    while origins do
        for i, origin in pairs(origins) do
            if package_deinstall_unused(origin) then del_done = true end
        end
        origins = del_done and table.keys(DELAYED_DELETES)
    end
end

-- deinstall package files after optionally creating a backup package
local function perform_deinstall(action)
    local p_o = action.pkg_old
    action:log {level = 1, "Deinstall old version", p_o.name}
    if Options.backup and not p_o:backup_old_package() then
        return false, "Failed to create backup package of " .. p_o.name
    end
    local out, err, exitcode = p_o:deinstall()
    if exitcode ~= 0 then
        return fail(action, "Failed to deinstall package " .. p_o.name, err)
    end
    action.done = true
    return true
end

-- peform delayed installation of ports not required as build dependencies after all ports have been built
local function perform_delayed_installation(action)
    local p_n = action.pkg_new
    action.pkg_new.pkgfile = Package.filename {p_n}
    local taskmsg = describe(action)
    action:log{taskmsg}
    assert(perform_installation(action),
           "Installation of " .. p_n.name .. " from " .. pkgfile .. " failed")
    Msg.success_add(taskmsg)
end
--]]

--[[
-------------------------------------------------------------------------------------
-- update changed port origin in the package db and move options file
local function perform_origin_change(action)
    local old_pkgs = action.old_pkgs
    if #old_pkgs > 1 then
        fail ("Too many old packages passed to package rename function")
    end
    local p_o = action.old_pkgs[1]
    action:log {"Change origin of", p_o.name, "from", p_o.origin.name, "to", action.pkg_new.origin.name}
    if PkgDb.update_origin(action.o_o, action.pkg_new.origin, p_o.name) then
        portdb_update_origin(action.o_o, action.pkg_new.origin)
        action.done = true
        return true
    end
end

-- update package name of installed package
local function perform_pkg_rename(action)
    local old_pkgs = action.old_pkgs
    if #old_pkgs > 1 then
        fail ("Too many old packages passed to package rename function")
    end
    local p_o = action.old_pkgs[1]
    local p_n = action.pkg_new
    action:log {"Rename package", p_o.name, "to", p_n.name}
    local out, err, exitcode = PkgDb.update_pkgname(p_o, p_n)
    if exitcode ~= 0 then
        return fail(action, "Rename package " .. p_o.name .. " to " .. p_n.name .. " failed", err)
    end
    pkgfiles_rename(action)
    action.done = true
    return not failed(action)
end
--]]

--[=[
--
local function action_enrich(action)
    --[[
   o_n (o_o, pkg_old)
   - in general same as o_o, but must be verified!!!
   - !!! lookup in MOVED port list (not fully deterministic due to lack of a "flavors required" flag in the list)
   - conflicts check required (via pkg_new (o_n)) to verify acceptable origin has been found
   --]]
    --[[
   pkg_new (o_n, pkg_old)
   - from make -V PKGNAME with FLAVOR and possibly DEFAULT_VERIONS override (must be derived from pkg_old !!!)
   - might depend on port OPTIONS
   - conflicts check required !!!
   --]]
    local function try_get_o_n(action)
        local function try_origin(origin)
            if origin and origin.exists then
                local p_n = origin.pkg_new
                --TRACE("P_N", origin.name, p_n)
                if p_n and p_n.name_base == action.pkg_old.name_base then -- XXX pkg_old !!!
                    p_n.origin = origin
                    action.pkg_new = p_n
                    --TRACE("TRY_GET_ORIGIN", p_n.name, origin.name)
                    return action
                end
            end
        end
        for p_o in ipairs(action.old_pkgs) do
            local o_o = p_o.origin
            if o_o then
                local result = try_origin(o_o)
                if result then
                    return result
                end
            end
        end
        return try_origin(determine_o_n(action))
        -- or
        -- try_origin (check_used_default_version (action))
    end
    --[[
   pkg_old (pkg_new)
   - in general the old name can be found by looking up the package name without version in the pkgdb
   - the lookup is not guaranteed to succeed due to package name changes (e.g. if FLAVORS have been added or removed from a port)
   --]]
    --[[
   pkg_old (o_o, pkg_new)
   - for installed packages always possible via pkgdb lookup of origin with flavor
   - implementation via ORIGIN_CACHE[o_o.name].old_pkgs
   - !!! possibly multiple results (due to multiple packages built with different DEFAULT_VERSIONS settings)
   - pkg_new may be used to select the correct result if multiple candidate results have been obtained
   --]]
    local function try_get_pkg_old(action)
        local p_n = rawget(action, "pkg_new")
        local o_n = p_n and rawget(p_n, "origin")
        if o_n then
            local p_o = rawget(o_n, "pkg_old")
            if not p_o then
            -- reverse move
            end
        end
        if p_n then
            local namebase = p_n.name_base
            local p_o = PkgDb.query {"%n-%v", namebase}
            if p_o and p_o ~= "" then
                local p = Package:new(p_o)
                -- action.o_o = p.origin -- XXX which origin to adjust in old_pkgs ??? !!!
            end
        end
    end

    --[[
   o_o (pkg_old)
   - for installed packages always possible via pkgdb
   - implementation via PACKAGES_CACHE[pkg_old.name].origin
   - if applicable: DEFAULT_VERSIONS parameter can be derived from the old package name (string match)
   --]]
    --
    if not rawget(action.pkg_new, "origin") and rawget(action, "pkg_old") then
        try_get_o_n(action)
    end
    --
    if not rawget(action, "pkg_old") and action.pkg_new then
        try_get_pkg_old(action)
    end
    --
    if not rawget(action.pkg_new, "origin") and rawget(action, "pkg_old") then
        try_get_o_n(action)
    end
    --
    local p_n = action.pkg_new
    local o_n = p_n and p_n.origin
    if o_n and o_n:check_excluded() or p_n and p_n:check_excluded() then
        action_set(action, "exclude")
        return action
    end
    for p_o in ipairs(action.old_pkgs) do
        local o_o = p_o.origin
        if o_o and o_o:check_excluded() then
            action_set(action, "exclude")
            return action
        end
    end
    --
    check_config_allow(action, rawget(action, "recursive"))

    --TRACE("CHECK_PKG_OLD_o_o", action.o_o, action.pkg_old, action.o_n, action.pkg_new)
    if not action.pkg_old and action.pkg_old.origin and action.pkg_new then
        local pkg_name = chomp(PkgDb.query {"%n-%v", action.pkg_new.name_base})
        --TRACE("PKG_NAME", pkg_name)
        if pkg_name then
            action.pkg_old = Package:new(pkg_name)
        end
    end

    --[[
   --Action.check_conflicts ("build_conflicts")
   Action.check_conflicts ("install_conflicts")

   --
--   Action.check_licenses ()

   -- build list of packages to install after all ports have been built
   Action.register_delayed_installs ()
   --]]
    --[[
   o_o (o_n, pkg_new)
   - lookup via pkg_new (without version) may be possible, but pkg_new may depend on parameters derived from pkg_old (DEFAULT_VERSIONS)
   - reverse lookup in the MOVED list until an entry in the pkgdb matches
   - the old origin might have been the same as the provided new origin (and in general will be ...)
   --]]
    return action -- NYI
end
--]=]
