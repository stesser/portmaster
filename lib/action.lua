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
local Origin = require("portmaster.origin")
local Options = require("portmaster.options")
local PkgDb = require("portmaster.pkgdb")
local Msg = require("portmaster.msg")
local Exec = require("portmaster.exec")
local Lock = require("portmaster.locks")

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
function tasks_count()
    return #ACTION_LIST
end

--
local function origin_changed(o_o, o_n)
    return o_o and o_o.name ~= "" and o_o ~= o_n and o_o.name ~= string.match(o_n.name, "^([^%%]+)%%")
end

--
local function action_set(action, verb)
    TRACE ("ACTION_SET", action.pkg_new or action.pkg_old, verb)
    verb = verb ~= "keep" and verb ~= "exclude" and verb or false
    action.action = verb
end

--
local function action_get (action)
    return action.action or "keep"
end

-- check whether the action denoted by "verb" has been registered
local function action_is (action, verb)
    local a = action_get(action)
    --TRACE ("ACTION_IS", action.pkg_new or action.pkg_old, a, verb)
    return verb and a == verb
end

-- Describe action to be performed
local function describe(action)
    local o_o = action.o_o
    local p_o = action.pkg_old
    local o_n = action.o_n
    local p_n = action.pkg_new
    TRACE("DESCRIBE", action.action, o_o, o_n, p_o, p_n)
    if action_is(action, "delete") then
        return string.format("De-install %s built from %s", p_o.name, o_o.name)
    elseif action_is(action, "change") then
        if p_o ~= p_n then
            local prev_origin = o_o and o_o ~= o_n and " (was " .. o_o.name .. ")" or ""
            return string.format("Change package name from %s to %s for port %s%s", p_o.name, p_n.name, o_n.name,
                                    prev_origin)
        else
            return string.format("Change origin of port %s to %s for package %s", o_o.name, o_n.name, p_n.name)
        end
    elseif action_is(action, "exclude") then
        return string.format("Skip excluded package %s installed from %s", p_o.name, o_o.name)
    elseif action_is(action, "upgrade") then
        local from
        if p_n and p_n.pkgfile then
            from = "from " .. p_n.pkgfile
        else
            from = "using " .. o_n.name .. (origin_changed(o_o, o_n) and " (was " .. o_o.name .. ")" or "")
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
end

--
local previous_action_co

local function log(action, args)
    TRACE("LOG", args, action)
    if PARAM.phase ~= "scan" then
        if not rawget(action, "startno_string") then
            action.startno_string = "[" .. tostring(action.startno) .. "/" .. tostring(#ACTION_LIST) .. "]"
            action:log{describe(action)}
        end
        local co = coroutine.running()
        args.start = args.start or co ~= previous_action_co
        previous_action_co = co
        table.insert(args, 1, action.startno_string)
        table.insert(args, 2, action.pkg_new.name .. ":")
    end
    TRACE("LOG", args)
    Msg.show(args)
end

-------------------------------------------------------------------------------------
-- record failure of an action and return false
local function fail(action, msg, errlog)
    if not rawget(action, "failed_msg") then
        action.failed_msg = msg
        TRACE("SET_FAILED", action.pkg_new.name, msg)
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
    local p_o = action.pkg_old
    assert(p_o, "No old package passed to pkgfiles_rename()")
    TRACE("PKGFILES_RENAME", action, p_o.name, p_n.name)
    local file_pattern = Package.filename{subdir = "*", ext = "t?*", p_o}
    TRACE("PKGFILES_RENAME-Pattern", file_pattern)
    local pkgfiles = glob(file_pattern)
    if pkgfiles then
        for _, pkgfile_old in ipairs(pkgfiles) do
            if access(pkgfile_old, "r") and not strpfx(pkgfile_old, PATH.packages_backup) then
                local pkgfile_new = path_concat(dirname(pkgfile_old), p_n.name .. pkgfile_old:gsub(".*(%.%w+)", "%1"))
                local _, err, exitcode = Exec.run{
                    as_root = true,
                    log = true,
                    CMD.mv, pkgfile_old, pkgfile_new
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
    local portdb_dir_old = action.o_o:portdb_path()
    if is_dir(portdb_dir_old) and access(portdb_dir_old .. "/options", "r") then
        local portdb_dir_new = action.o_n:portdb_path()
        if is_dir(portdb_dir_new) then
            return fail(action, "Target directory does already exist")
        end
        local _, err, exitcode = Exec.run{
            as_root = true,
            log = true,
            CMD.mv, portdb_dir_old, portdb_dir_new
        }
        if exitcode ~= 0 then
            return fail(action, "Failed to rename " .. portdb_dir_old .. " to " .. portdb_dir_new .. " in the package database", err)
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
    local o_n = action.o_n
    local pkgname = action.pkg_new.name
    local pkgfile = action.pkg_new.pkg_filename -- (PATH.packages .. "All", pkgname, PARAM.package_format)
    TRACE("PACKAGE_CREATE", o_n, pkgname, pkgfile)
    if Options.skip_recreate_pkg and access(pkgfile, "r") then
        action:log{"The existing package file will not be overwritten"}
    else
        action:log{"Create a package from staging area of port", o_n.name}
        local jailed = Options.jailed
        local as_root = PARAM.packages_ro
        local base = (as_root or jailed) and PATH.tmpdir or PATH.packages -- use random tempdir !!!
        local sufx = "." .. PARAM.package_format
        local _, err, exitcode = o_n:port_make{
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
                    tmpfile = path_concat(PARAM.jailbase, tmpfile)
                end
                if as_root then
                    Exec.run{
                        as_root = true,
                        CMD.chown, "0:0", tmpfile
                    }
                end
                _, err, exitcode = Exec.run{
                    as_root = as_root,
                    CMD.mv, tmpfile, pkgfile
                }
            end
        end
        if exitcode ~= 0 or not Options.dry_run and not access(pkgfile, "r") then
            return fail(action, "Package file " .. pkgfile .. " could not be created", err)
        end
        action.pkg_new:category_links_create(o_n.categories)
        action:log{"Package saved to file", pkgfile}
    end
    return true
end

-- check conflicts of new port with installed packages (empty table if no conflicts found)
local function conflicting_pkgs(action, mode)
    local origin = action.o_n
    if origin and origin.build_conflicts and origin.build_conflicts[1] then
        local list = {}
        local make_target = mode == "build_conflicts" and "check-build-conflicts" or "check-conflicts"
        local conflicts_table, err, exitcode = origin:port_make{
            table = true,
            safe = true,
            make_target
        }
        if exitcode == 0 then
            for _, line in ipairs(conflicts_table) do
                TRACE("CONFLICTS", line)
                local pkgname = line:match("^%s+(%S+)%s*")
                if pkgname then
                    table.insert(list, Package:new(pkgname))
                elseif #list > 0 then
                    break
                end
            end
        end
        return list
    end
end

-------------------------------------------------------------------------------------
-- wait for dependencies to become available
local function pkgs_from_origin_tables(...)
    local pkgs = {}
    for _, t in ipairs({...}) do
        for _, origin in ipairs(t) do
            if not string.match(origin, ":.*") then -- ignore special depends
                local o = Origin.get(origin)
                TRACE("PKG_FROM_ORIGIN_TABLES", origin, o)
                local p = o.pkg_new.name
                pkgs[#pkgs + 1] = p
            end
        end
    end
    TRACE("PKGS_FROM_ORIGIN_TABLES", pkgs, ...)
    return pkgs
end

--
local function get(pkgname)
    return rawget(ACTION_CACHE, pkgname)
end

-------------------------------------------------------------------------------------
-- perform all steps required to build a port (extract, patch, build, stage, opt. package)

-- de-install (possibly partially installed) port after installation failure
local function deinstall_failed(action)
    action:log{"Installation from", action.o_n.name, "failed, deleting partially installed package"}
    local out, err, exitcode = action.o_n:port_make{
        log = true,
        jailed = true,
        as_root = true,
        "deinstall"
    }
    return exitcode == 0
end

--
local function perform_provide(action)
    TRACE("PROVIDE", action.pkg_new.name)
    return action.pkg_new:install()
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
local PkgDbLock

-- install or upgrade a port
local function perform_install_or_upgrade(action)
    local p_o = action.pkg_old
    local pkgname_old = p_o and p_o.name
    local p_n = action.pkg_new
    local pkgname_new = p_n.name
    local pkgfile = p_n.pkgfile
    local o_n = action.o_n
    local portname = o_n.name -- o_n.port ???
    local build_depends = o_n.build_depends
    local special_depends = o_n.special_depends        -- check for special license and ask user to accept it (may require make extract/patch)
    local build_dep_pkgs

    local function wait_for_distfiles()
        o_n:fetch_wait()
    end
    local function check_license()
        -- may depend on OPTIONS set by make configure
        if not PARAM.disable_licenses then
            if not o_n:check_license() then
                return fail(action, "License check failed")
            end
        end
    end
    -- clean work directory and special build depends (might also be delayed to just before program exit)
    local function port_clean()
        local function do_clean(origin)
            TRACE("DO_CLEAN", origin)
            local must_clean = access(origin.wrkdir, "r")
            if must_clean then
                local need_root = not access(origin.wrkdir, "w") or not access(path_concat(origin.wrkdir, ".."), "w")
                TRACE("DO_CLEAN_AS", origin.name, need_root)
                return origin:port_make{
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
        action:log{"Clean work directory of port", o_n.name}
        local out, _, exitcode = do_clean(o_n)
        if exitcode ~= 0 then
            return fail(action, "Failed to clean the work directory of " .. o_n.name, out)
        end
        for _, origin_target in ipairs(special_depends or {}) do
            TRACE("PORT_CLEAN_SPECIAL_DEPENDS", o_n.name, origin_target)
            local target = target_part(origin_target)
            local origin = Origin:new(origin_target:gsub(":.*", ""))
            if target ~= "fetch" and target ~= "checksum" then
                action:log{"Clean work directory of special dependency", origin.name}
                out, _, exitcode = do_clean(origin)
                if exitcode ~= 0 then
                    return fail(action, "Failed to clean the work directory of " .. origin.port, out)
                end
            end
        end
    end
    local function special_deps()
        TRACE("SPECIAL:", #special_depends, special_depends[1])
        if #special_depends > 0 then
            TRACE("SPECIAL_DEPENDS", special_depends)
            -- local special_depends = action.o_n.special_depends
            for _, origin_target in ipairs(special_depends) do
                -- print ("SPECIAL_DEPENDS", origin_target)
                local target = target_part(origin_target)
                local origin = Origin:new(origin_target:gsub(":.*", "")) -- define function to strip the target ???
                -- assert (origin:wait_checksum ())
                if target ~= "fetch" and target ~= "checksum" then
                    -- extract from package if $target=stage and _packages is set? <se>
                    local out, _, exitcode = origin:port_make{
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
                        fail(action, "Failed to provide special dependency " .. origin_target .. ":", out)
                    end
                end
            end
        end
    end
    local function extract()
        local wrkdir_parent = path_concat(o_n.wrkdir, "..")
        action:log{"Extract port", portname}
        local _, _, exitcode = Exec.run{
            CMD.mkdir, "-p", wrkdir_parent
        }
        if exitcode ~= 0 then
            Exec.run{
                as_root = true,
                CMD.mkdir, "-p", wrkdir_parent
            }
            Exec.run{
                as_root = true,
                CMD.chown, PARAM.uid, wrkdir_parent
            }
        end
        local out, _, exitcode = o_n:port_make{
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
            fail(action, "Build failed in extract phase:", out)
        end
    end
    local function patch()
        action:log{"Patch port", portname}
        local out, _, exitcode = o_n:port_make{
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
            fail(action, "Build failed in patch phase:", out)
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
        action:log{"Build port", portname}
        local out, _, exitcode = o_n:port_make{
            log = true,
            errtoout = true,
            jailed = true,
            "NO_DEPENDS=1",
            "DISABLE_CONFLICTS=1",
            "_OPTIONS_OK=1",
            "MAKE_JOBS_NUMBER_LIMIT=" .. action.jobs,
            "build"
        }
        if exitcode ~= 0 then
            fail(action, "Build failed in build phase:", out)
        end
    end
    local function stage()
        --stage port
        action:log{"Install port", portname, "to staging area"}
        local out, _, exitcode = o_n:port_make{
            log = true,
            errtoout = true,
            jailed = true,
            "NO_DEPENDS=1",
            "DISABLE_CONFLICTS=1",
            "_OPTIONS_OK=1",
            "stage"
        }
        if exitcode ~= 0 then
            fail(action, "Build failed in stage phase:", out)
        end
    end
    local function check_build_deps()
        for _, p in ipairs(build_dep_pkgs) do
            TRACE("FAILED?", p)
            local a = get(p)
            if not a or failed(a) then
                return fail(action, "Skipped because of failed dependency: " .. p)
            end
        end
    end
    -- create package file from staging area
    local function create_package()
        if Options.create_package then
            package_create(action)
        end
    end
    local function preserve_old_shared_libraries()
        -- preserve currently installed shared libraries
        if Options.save_shared and not p_o:shlibs_backup() then
            return fail(action, "Could not save old shared libraries to compat directory")
        end
    end
    local function preserve_precious()
        -- preserve pkg-static even when deleting the "pkg" package
        if portname == "ports-mgmt/pkg" then
            Exec.run{
                as_root = true,
                CMD.unlink, CMD.pkg .. "~"
            }
            Exec.run{
                as_root = true,
                CMD.ln, CMD.pkg, CMD.pkg .. "~"
            }
        end
    end
    local function create_backup_package()
        -- create backup package file from installed files
        local create_backup = pkgname_old ~= pkgname_new or not pkgfile
        if create_backup then
            local out, err, exitcode = p_o:backup_old_package()
            if exitcode ~= 0 then
                return fail(action, "Create backup package for " .. pkgname_old, err)
            end
        end
    end
    local function delete_old_package()
        -- delete old package version
        local out, err, exitcode = p_o:deinstall()
        if exitcode ~= 0 then
            fail(action, "Failed to deinstall old version", err)
        end
    end
    local function recover_precious()
        -- restore pkg-static if it has been preserved
        if portname == "ports-mgmt/pkg" then
            Exec.run{
                as_root = true,
                CMD.unlink, CMD.pkg
            }
            Exec.run{
                as_root = true,
                CMD.mv, CMD.pkg .. "~", CMD.pkg
            }
        end
    end
    local function install_from_package()
        -- try to install from package
        TRACE("PERFORM_INSTALLATION/PKGFILE", p_n.pkgfile)
        action:log{"Install from package file", p_n.pkgfile}
        -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
        local _, err, exitcode = p_n:install()
        if exitcode ~= 0 then
            p_n:deinstall() -- ignore output and exitcode
            if not Options.jailed then
                if p_o then
                    _, err, exitcode = p_o:recover()
                    if exitcode ~= 0 then
                        fail(action, "Could not re-install previously installed version after failed installation", err)
                    end
                end
            end
            --[[ rename only if failure was not due to a conflict with an installed package!!!
            {"Rename", pkgfile, "to", pkgfile .. ".NOTOK after failed installation")
            os.rename(pkgfile, pkgfile .. ".NOTOK")
            --]]
            fail(action, "Failed to install from package file " .. p_n.pkgfile, err)
        end
    end
    local function install_from_stage_area()
        -- try to install new port
        TRACE("PERFORM_INSTALLATION/PORT", portname)
        action:log{"Install", pkgname_new, "built from", portname, "on base system"}
        -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
        local out, err, exitcode = o_n:install()
        --InstalledLock:release(pkgname_new)
        if exitcode ~= 0 then
            -- OUTPUT
            deinstall_failed(action)
            if p_o then
                local out, err, exitcode = p_o:recover()
                if exitcode ~= 0 then
                    return fail(action, "Could not re-install previously installed version after failed installation", err)
                end
            end
            fail(action, "Failed to install port", portname .. ":", err)
        end
    end
    -- perform actual installation from a port or package
    local function post_install_fixup()
        TRACE("PERFORM_INSTALLATION", action)
        -- set automatic flag to the value the previous version had
        if p_o and p_o.is_automatic then
            p_n:automatic_set(true)
        end
    end
    local function cleanup_old_shared_libraries()
        -- remove all shared libraries replaced by new versions from shlib backup directory
        if p_o and Options.save_shared then
            p_o:shlibs_backup_remove_stale() -- use action as argument???
        end
    end
    local function delete_stale_pkgfiles()
        -- delete stale package files
        if pkgname_old then
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

    TRACE("P", p_n.name, p_n)
    -- has a package been identified to be used instead of building the port?
    local buildrequired = not p_n.pkgfile or rawget (action, "force") or not (Options.packages or Options.packages_build and not p_n.is_run_dep)
    TRACE("BUILDREQUIRED", buildrequired, rawget (action, "force"), Options.packages)
    local skip_install = (Options.skip_install or Options.jailed) and not p_n.is_build_dep -- NYI: and BUILDDEP[o_n]
    if not skip_install then -- XXX test whether this specific package is actually to be installed !!!
        RunnableLock = RunnableLock or Lock.new("RunnableLock")
        -- >>>> RunnableLock(p_n.name)
        RunnableLock:acquire(p_n.name) -- acquire exclusive lock until package is runnable
    end
    if buildrequired then
        -- if not installing from a package file ...
        WorkDirLock = WorkDirLock or Lock.new("WorkDirLock")
        -- >>>> WorkDirLock(o_n.wrkdir)
        WorkDirLock:acquire{tag=p_n.name, o_n.wrkdir}
        TRACE("perform_portbuild", portname, pkgname_new, special_depends)
        -- wait for all packages of build dependencies being available
        -- >>>> RunnableLock(build_dep_pkgs, SHARED)
        build_dep_pkgs = pkgs_from_origin_tables(build_depends, special_depends)
        build_dep_pkgs.shared = true
        build_dep_pkgs.tag = pkgname_new
        RunnableLock:acquire(build_dep_pkgs) -- acquire shared lock to wait for build deps to become runnable
        build_step(check_build_deps)
        JobsLock = JobsLock or Lock.new("JobsLock", PARAM.ncpu) -- limit number of processes to one per (virtual) core
        -- XXX action.jobs = action.jobs or 4 -- PARAM.ncpu -- number of processes this build might spawn -- to be set in strategy module
        local jobslockitems = {weight = action.jobs}
        -- >>>> JobsLock(jobslockitems)
        JobsLock:acquire(jobslockitems)
        if not Options.no_pre_clean then
            build_step(port_clean)
        end
        build_step(wait_for_distfiles)
        build_step(check_license)
        build_step(special_deps)
        build_step(extract)
        build_step(patch)
        --build_step(conflicts)
        build_step(build)
        JobsLock:release(jobslockitems)
        -- <<<< JobsLock(jobslockitems)
        build_step(stage)
        build_dep_pkgs.shared = true
        RunnableLock:release(build_dep_pkgs)
        -- <<<< Packagelock(build_dep_pkgs, SHARED)
        build_step(create_package)
    end
    -- install build depends immediately but optionally delay installation of other ports
    if not skip_install then
        TRACE("PKGFILE2", buildrequired, pkgfile)
        -- prepare installation, if this is an upgrade (and not a fresh install)
        if pkgname_old then
            TRACE("PERFORM_INSTALLATION/REMOVE_OLD_PKG", pkgname_old)
            if not Options.jailed or PARAM.phase == "install" then
                build_step(create_backup_package)
                build_step(preserve_old_shared_libraries)
                build_step(preserve_precious)
                build_step(delete_old_package)
                build_step(recover_precious)
            end
        end
        PkgDbLock = PkgDbLock or Lock.new("PkgDbLock", 1)
        -- >>>> PkgDbLock(1)
        PkgDbLock:acquire{weight = 1} -- only one installation at a time due to exclusive lock on pkgdb
        if buildrequired then
            build_step(install_from_stage_area)
        else
            build_step(install_from_package)
        end
        PkgDbLock:release{weight = 1}
        -- <<<< PkgDbLock(1)
        RunnableLock:release(p_n.name)
        -- <<<< RunnableLock(p_n.name)
        --build_step(fetch_pkg_message)
        build_step(post_install_fixup)
    end
    if buildrequired then
        -- preserve file names and hashes of distfiles from new port
        -- NYI distinfo_cache_update (o_n, pkgname_new)
        -- backup clean port directory and special build depends (might also be delayed to just before program exit)
        if not Options.no_post_clean then
            build_step(port_clean)
            -- delete old distfiles
            -- NYI distfiles_delete_old (o_n, pkgname_old) -- OUTPUT
        end
        WorkDirLock:release{o_n.wrkdir}
        -- <<<< WorkDirLock(o_n.wrkdir)
    end
    build_step(cleanup_old_shared_libraries)
    build_step(delete_stale_pkgfiles)
    -- report success or failure ...
    if not Options.dry_run then
        local failed_msg, failed_log = failed(action)
        if failed_msg then
            action:log{describe(action), "failed:", failed_msg}
            if failed_log then
                Msg.show{verbatim = true, failed_log, "\n"}
            end
        else
            action:log{describe(action), "successfully completed."}
        end
    end
    return not failed(action)
end

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
--]]

-- deinstall package files after optionally creating a backup package
local function perform_deinstall(action)
    local p_o = action.pkg_old
    action:log{level=1, "Deinstall old version", p_o.name}
    if Options.backup and not p_o:backup_old_package() then
        return false, "Failed to create backup package of " .. p_o.name
    end
    local out, err, exitcode = p_o:deinstall()
    if exitcode ~= 0 then
        return fail(action, "Failed to deinstall package " .. p_o.name .. ": ", err)
    end
    action.done = true
    return true
end

--[[
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

-------------------------------------------------------------------------------------
-- update changed port origin in the package db and move options file
local function perform_origin_change(action)
    action:log{"Change origin of", action.pkg_old.name, "from", action.o_o.name, "to", action.o_n.name}
    if PkgDb.update_origin(action.o_o, action.o_n, action.pkg_old.name) then
        portdb_update_origin(action.o_o, action.o_n)
        action.done = true
        return true
    end
end

-- update package name of installed package
local function perform_pkg_rename(action)
    local p_o = action.pkg_old
    local p_n = action.pkg_new
    action:log{"Rename package", p_o.name, "to", p_n.name}
    local out, err, exitcode = PkgDb.update_pkgname(p_o, p_n)
    if exitcode ~= 0 then
        return fail(action, "Rename package " .. p_o.name .. " to " .. p_n.name .. " failed:", err)
    end
    pkgfiles_rename(action)
    action.done = true
    return not failed(action)
end

-------------------------------------------------------------------------------------
local function perform_upgrades(action_list)
    -- install or upgrade required packages
    for _, action in ipairs(action_list) do
        -- if Options.hide_build is set the buildlog will only be shown on errors
        local o_n = rawget(action, "o_n")
        local is_interactive = o_n and o_n.is_interactive
        if Options.hide_build and not is_interactive then
            -- set to_tty = false for shell commands
            --BUILDLOG = tempfile_create("BUILD_LOG")
        end
        local result
        -- print ("DO", action.verb, action.pkg_new.name)
        if action_is(action, "delete") then
            result = perform_deinstall(action)
        elseif action_is(action, "upgrade") then
            Exec.spawn(perform_install_or_upgrade, action)
            result = true
        elseif action_is(action, "change") then
            if action.pkg_old.name ~= action.pkg_new.name then
                result = perform_pkg_rename(action)
            elseif action.o_o.name ~= action.o_n.name then
                result = perform_origin_change(action)
            end
        elseif action_is(action, "provide") or action_is(action, "keep") then
            if Options.jailed then
                if action.pkg_new.pkgfile then
                    result = perform_provide(action)
                else
                    Exec.spawn(perform_install_or_upgrade, action)
                    result = true
                end
            else
                result = true -- nothing to be done
            end
        elseif action_is(action, "exclude") then
            result = true -- do nothing
        else
            error("unknown verb in action: " .. (action.verb or "<nil>"))
        end
        if result then
            --[[
            if BUILDLOG then
                tempfile_delete("BUILD_LOG")
                BUILDLOG = nil
            end
            -- NYI: o_n:perform_post_build_deletes ()
            --]]
        else
            return false
        end
    end
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
            if action_is (v, "upgrade") then
                local p_o = v.pkg_old
                local p_n = v.pkg_new
                if p_o == p_n then
                    incr("reinstalls")
                elseif p_o == nil then
                    incr("installs")
                else
                    incr("upgrades")
                end
            elseif action_is (v, "delete") then
                incr("deletes")
            elseif action_is (v, "change") then
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
    local pt = action.o_o and action.o_o.old_pkgs
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

--
local function determine_pkg_new(action, k)
    local p = action.o_n and action.o_n.pkg_new
    if not p and action.o_o and action.pkg_old then
        p = action.o_o.pkg_new
        --[[
      if p and p.name_base_major ~= action.pkg_old.name_base_major then
	 p = nil -- further tests required !!!
      end
      --]]
    end
    return p
end

--
local function determine_o_o(action, k)
    -- print ("OO:", action.pkg_old, (rawget (action, "pkg_old") and (action.pkg_old).origin or "-"), action.pkg_new, (rawget (action, "pkg_new") and (action.pkg_new.origin or "-")))
    local o = action.pkg_old and rawget(action.pkg_old, "origin") or action.pkg_new and action.pkg_new.origin -- NOT EXACT
    return o
end

--
local function verify_origin(o)
    if o and o.name and o.name ~= "" then
        local n = o.path .. "/Makefile"
        -- print ("PATH", n)
        return access(n, "r")
    end
end

--
local function determine_o_n(action, k)
    local o = action.pkg_old and action.pkg_old.origin
    if o then
        local mo = Origin.lookup_moved_origin(o)
        if mo and mo.reason or verify_origin(mo) then
            return mo
        end
        if verify_origin(o) then
            return o
        end
    end
end

--
local function compare_versions_old_new(action, k)
    local p_o = action.pkg_old
    local p_n = action.pkg_new
    if p_o and p_n then
        return Package.compare_versions(p_o, p_n)
    end
end

--
local function determine_action(action, k)
    local p_o = action.pkg_old -- keep next 4 lines in this order!
    local o_n = action.o_n
    local o_o = action.o_o
    local p_n = action.pkg_new
    local function need_upgrade()
        if Options.force or action.build_type == "provide" or action.build_type == "checkabi" or rawget(action, "force") then
            return true -- add further checks, e.g. changed dependencies ???
        end
        if not o_o or o_o.flavor ~= o_n.flavor then
            return true
        end
        if p_o == p_n then
            return false
        end
        if not p_o or not p_n or p_o.version ~= p_n.version then
            return true
        end
        --[[
      local pfx_o = string.match (p_o.name, "^([^-]+)-[^-]+-%S+")
      local pfx_n = string.match (p_n.name, "^([^-]+)-[^-]+-%S+")
      if pfx_o ~= pfx_n then
	 --print ("PREFIX MISMATCH:", pfx_o, pfx_n)
	 return true
      end
      --]]
    end
    local function excluded()
        if p_o and rawget(p_o, "is_locked") or p_n and rawget(p_n, "is_locked") then
            return true -- ADD FURTHER CASES: excluded, broken without --try-broken, ignore, ...
        end
    end

    TRACE ("DETERMINE_ACTION", p_o, p_n, o_o, o_n)
    if excluded() then
        action_set (action, "exclude")
    elseif not p_n then
        action_set (action, "delete")
    elseif not p_o or need_upgrade() then
        action_set (action, "upgrade")
    elseif p_o ~= p_n or origin_changed(o_o, o_n) then
        action_set (action, "change")
    else
        action_set (action, "keep")
    end
    return action.action
end

--
local function clear_cached_action(action)
    local pkg_old = action.pkg_old
    local pkg_new = action.pkg_new
    if action_is(action, "delete") then
        if ACTION_CACHE[pkg_old] then
            ACTION_CACHE[pkg_old.name] = nil
        end
    end
    if ACTION_CACHE[pkg_new] then
        ACTION_CACHE[pkg_new.name] = nil
    end
end

local function set_cached_action(action)
    local function check_and_set(field)
        local v = rawget(action, field)
        if v then
            local n = v.name
            if n and n ~= "" then
                if ACTION_CACHE[n] and ACTION_CACHE[n] ~= action then
                    -- error ()
                    TRACE("SET_CACHED_ACTION_CONFLICT", describe(ACTION_CACHE[n]), describe(action))
                end
                ACTION_CACHE[n] = action
                TRACE("SET_CACHED_ACTION", field, n)
            else
                error("Empty package name " .. field .. " " .. describe(action))
            end
        end
    end
    assert(action, "set_cached_action called with nil argument")
    TRACE("SET_ACTION", describe(action))
    check_and_set("pkg_old")
    if not action_is(action, "delete") then
        check_and_set("pkg_new")
    end
    return action
end

--
local function get_pkgname(action)
    if action.pkg_old and action_is(action, "delete") then
        return action.pkg_old.name
    elseif action.pkg_new then
        return action.pkg_new.name
    end
end

--
local function fixup_conflict(action1, action2)
    TRACE("FIXUP", action1.action, action2.action)
    if action2.action and (not action1.action or action1.action > action2.action) then
        action1, action2 = action2, action1 -- normalize order: action1 < action2 or action2 == nil
    end
    local pkgname = get_pkgname(action1) or get_pkgname(action2)
    local a1 = action1.action
    local a2 = action2.action
    if a1 == "upgrade" then
        if not a2 then -- attempt to upgrade some port to already existing package
            TRACE("FIXUP_CONFLICT1", describe(action1))
            TRACE("FIXUP_CONFLICT2", describe(action2))
            action_set (action1, "delete")
            action1.o_o = action1.o_o or action1.o_n
            action1.o_n = nil
            action1.pkg_old = action1.pkg_old or action1.pkg_new
            action1.pkg_new = nil
            TRACE("FIXUP_CONFLICT->", describe(action1))
        elseif a2 == "upgrade" then
            TRACE("FIXUP_CONFLICT1", describe(action1))
            TRACE("FIXUP_CONFLICT2", describe(action2))
            if action1.pkg_new == action2.pkg_new then
                for k, v1 in pairs(action1) do
                    local v2 = rawget(action2, k)
                    if v1 and not v2 then
                        action2[k] = v1
                    end
                end
                action_set (action1, "keep")
                TRACE("FIXUP_CONFLICT->", describe(action2))
            else
                -- other cases
            end
        else
            -- other cases
        end
    else
        -- other cases
    end
    --error("Duplicate actions for " .. pkgname .. ":\n#	1) " .. (action1 and describe(action1) or "") .. "\n#	2) " ..
    --          (action2 and describe(action2) or ""))
end

-- object that controls the upgrading and other changes
local function cache_add(action)
    local pkgname = get_pkgname(action)
    local action0 = ACTION_CACHE[pkgname]
    if action0 and action0 ~= action then
        clear_cached_action(action)
        clear_cached_action(action0)
        fixup_conflict(action, action0) -- re-register in ACTION_CACHE after fixup???
        --error("Duplicate actions resolved for " .. pkgname .. ":\n#	1) " .. (action and describe(action) or "") .. "\n#	2) " ..
        --          (action0 and describe(action0) or ""))
        set_cached_action(action0)
    end
    return set_cached_action(action)
end

--
local function lookup_cached_action(args) -- args.pkg_new is a string not an object!!
    local p_o = rawget(args, "pkg_old")
    local p_n = rawget(args, "pkg_new") or rawget(args, "o_n") and args.o_n.pkg_new
    local action = p_n and ACTION_CACHE[p_n.name] or p_o and ACTION_CACHE[p_o.name]
    TRACE("CACHED_ACTION", args.pkg_new, args.pkg_old, action and action.pkg_new and action.pkg_new.name,
          action and action.pkg_old and action.pkg_old.name, "END")
    return action
end

--
local function check_config_allow(action, recursive)
    local origin = action.o_n
    TRACE("CHECK_CONFIG_ALLOW", origin, recursive)
    if not origin then
        return
    end
    local function check_ignore(name, field)
        TRACE("CHECK_IGNORE", origin.name, name, field, rawget(origin, field))
        if rawget(origin, field) then
            fail(action, "Is marked " .. name .. " and will be skipped: " .. origin[field] .. "\n" ..
                    "If you are sure you can build this port, remove the " .. name .. " line in the Makefile and try again")
        end
    end
    -- optionally or forcefully configure port
    local function configure(origin, force)
        local target = force and "config" or "config-conditional"
        return origin:port_make{
            to_tty = true,
            as_root = PARAM.port_dbdir_ro,
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
            TRACE("NO_OPTIONS_FILE", origin)
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
            if origin and verify_origin(origin) then
                local p_n = origin.pkg_new
                TRACE("P_N", origin.name, p_n)
                if p_n and p_n.name_base == action.pkg_old.name_base then
                    action.pkg_new = p_n
                    action.o_n = origin
                    TRACE("TRY_GET_ORIGIN", p_n.name, origin.name)
                    return action
                end
            end
        end
        return try_origin(action.o_o) or try_origin(determine_o_n(action))
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
        local o_n = rawget(action, "o_n")
        if o_n then
            local p_o = rawget(o_n, "pkg_old")
            if not p_o then
                -- reverse move
            end
        end
        local p_n = action.pkg_new
        if p_n then
            local namebase = p_n.name_base
            local p_o = PkgDb.query {"%n-%v", namebase}
            if p_o and p_o ~= "" then
                local p = Package:new(p_o)
                action.o_o = p.origin
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
    if not rawget(action, "o_n") and rawget(action, "pkg_old") then
        try_get_o_n(action)
    end
    --
    if not rawget(action, "pkg_old") and action.pkg_new then
        try_get_pkg_old(action)
    end
    --
    if not rawget(action, "o_n") and rawget(action, "pkg_old") then
        try_get_o_n(action)
    end
    --
    if action.o_o and action.o_o:check_excluded() or action.o_n and action.o_n:check_excluded() or action.pkg_new and
        action.pkg_new:check_excluded() then
        action_set (action, "exclude")
        return action
    end
    --
    check_config_allow(action, rawget(action, "recursive"))

    TRACE("CHECK_PKG_OLD_o_o", action.o_o, action.pkg_old, action.o_n, action.pkg_new)
    if not action.pkg_old and action.o_o and action.pkg_new then
        local pkg_name = chomp(PkgDb.query {"%n-%v", action.pkg_new.name_base})
        TRACE("PKG_NAME", pkg_name)
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

--
local function check_licenses()
    local accepted = {}
    local accepted_opt = nil
    local function check_accepted(licenses)
        --
    end
    local function set_accepted(licenses)
        -- LICENSES_ACCEPTED="L1 L2 L3"
    end
    for _, action in ipairs(ACTION_LIST) do
        local o = rawget(action, "o_n")
        if o and rawget(o, "license") then
            if not check_accepted(o.license) then
                action:log{"Check license for", o.name, o.license}
                -- o:port_make {"-DDEFER_CONFLICTS_CHECK", "-DDISABLE_CONFLICTS", "extract", "ask-license", accepted_opt}
                -- o:port_make {"clean"}
                set_accepted(o.license)
            end
        end
    end
end

--[[
local function port_options()
    Msg.show {level = 2, start = true, "Check for new port options"}
    for i, a in ipairs(ACTION_LIST) do
        local o = rawget(a, "o_n")
        -- if o then print ("O", o, o.new_options) end
        if o and rawget(o, "new_options") then
            a:log{"Set port options for port", o.name}
        end
    end
    Msg.show {level = 2, start = true, "Check for new port options has completed"}
end
--]]

--
local function check_conflicts(mode)
    Msg.show {level = 2, start = true, "Check for conflicts between requested updates and installed packages"}
    for _, action in ipairs(ACTION_LIST) do
        local o_n = rawget(action, "o_n")
        if o_n and o_n[mode] then
            local conflicts_table = conflicting_pkgs(action, mode)
            if conflicts_table and #conflicts_table > 0 then
                local text = ""
                for _, pkg in ipairs(conflicts_table) do
                    text = text .. " " .. pkg.name
                end
                Msg.show{"Conflicting packages for", o_n.name, text}
            end
        end
    end
    Msg.show {level = 2, start = true, "Check for conflicts has been completed"}
end

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache()
    local t = ACTION_CACHE
    for _, v in ipairs(table.keys(t)) do
        TRACE("ACTION_CACHE", v, t[v])
    end
end

-------------------------------------------------------------------------------------
local function __newindex(action, n, v)
    TRACE("SET(a)", rawget(action, "pkg_new") and action.pkg_new.name or rawget(action, "pkg_old") and action.pkg_old.name, n, v)
    if v and (n == "pkg_old" or n == "pkg_new") then
        ACTION_CACHE[v.name] = action
    end
    rawset(action, n, v)
end

local actions_started = 0

local function __index(action, k)
    local function __depends(action, k)
        local o_n = action.o_n
        if o_n then
            TRACE("DEP_REF", k, o_n[k])
            return o_n[k]
            -- k = string.match (k, "[^_]+")
            -- return o_n.depends (action.o_n, k)
        end
    end
    local function __short_name(action, k)
        return action.pkg_new and action.pkg_new.name or action.pkg_old and action.pkg_old.name or action.o_n and
                   action.o_n.name or action.o_o and action.o_o.name or "<unknown>"
    end
    local function __startno (action, k)
        actions_started = actions_started + 1
        return actions_started -- action.listpos
    end
    local function __jobs (action, k)
        return PARAM.ncpu // 2
    end
    local dispatch = {
        pkg_old = determine_pkg_old,
        pkg_new = determine_pkg_new,
        vers_cmp = compare_versions_old_new,
        o_o = determine_o_o,
        o_n = determine_o_n,
        build_depends = __depends,
        run_depends = __depends,
        action = determine_action,
        short_name = __short_name,
        startno = __startno,
        jobs = __jobs,
    }

    TRACE("INDEX(a)", k)
    local w = rawget(action.__class, k)
    if w == nil then
        rawset(action, k, false)
        local f = dispatch[k]
        if f then
            w = f(action, k)
            if w then
                rawset(action, k, w)
            else
                w = false
            end
        else
            error("illegal field requested: Action." .. k)
        end
        TRACE("INDEX(a)->", k, w)
    else
        TRACE("INDEX(a)->", k, w, "(cached)")
    end
    return w
end

local mt = {
    __index = __index,
    __newindex = __newindex, -- DEBUGGING ONLY
    __tostring = describe,
}

--
local function new(Action, args)
    if args then
        local action
        TRACE("ACTION", args.pkg_old or args.pkg_new or args.o_n)
        action = lookup_cached_action(args)
        if action then
            action.recursive = rawget(args, "recursive") -- set if re-entering this function
            action.force = rawget(action, "force") or args.force -- copy over some flags
            if args.pkg_old then
                if rawget(action, "pkg_old") then
                    -- assert (action.pkg_old.name == args.pkg_old.name, "Conflicting pkg_old: " .. action.pkg_old.name .. " vs. " .. args.pkg_old.name)
                    action_set (action, "delete")
                    args.pkg_new = nil
                    args.o_n = nil
                end
                action.pkg_old = args.pkg_old
            end
            if args.pkg_new then
                if rawget(action, "pkg_new") then
                    assert(action.pkg_new.name == args.pkg_new.name,
                           "Conflicting pkg_new: " .. action.pkg_new.name .. " vs. " .. args.pkg_new.name)
                else
                    action.pkg_new = args.pkg_new
                end
            end
            if args.o_n then
                if rawget(action, "o_n") then
                    assert(action.o_n.name == args.o_n.name, "Conflicting o_n: " .. action.o_n.name .. " vs. " .. args.o_n.name)
                else
                    local p = args.o_n.pkg_new
                    action.o_n = p.origin -- could be aliased origin and may need to be updated to canonical origin object
                end
            end
        else
            action = args
            action.__class = Action
            setmetatable(action, mt)
        end
        if not action_enrich(action) then
            if action_is(action, "exclude") then
                if action.o_n then
                    action.o_n:delete() -- remove this origin from ORIGIN_CACHE
                end
                args.recursive = true -- prevent endless config loop
                return new(Action, args)
            end
        end
        if not action_is(action, "exclude") and not action_is(action, "keep") then
            if not rawget(action, "listpos") then
                table.insert(ACTION_LIST, action)
                action.listpos = #ACTION_LIST
                Msg.show{tostring(#ACTION_LIST) .. ".", describe(action)}
            end
            if action_is(action, "upgrade") then
                action.o_n:fetch() -- XXX call fetch() only when not installing from package file !!!
            end
        end
        return cache_add(action)
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
