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

-- ----------------------------------------------------------------------------------
local Origin = require("Origin")
local Options = require("Options")
local PkgDb = require("PkgDb")
local Jail = require("Jail")
local Msg = require("Msg")
local Progress = require("Progress")
local Distfile = require("Distfile")
local Exec = require("Exec")

-- ----------------------------------------------------------------------------------
local P = require("posix")
local glob = P.glob

local P_US = require("posix.unistd")
local access = P_US.access
local chown = P_US.chown

-- ----------------------------------------------------------------------------------
local function origin_changed(o_o, o_n)
    return o_o and o_o.name ~= "" and o_o ~= o_n and o_o.name ~=
               string.match(o_n.name, "^([^%%]+)%%")
end

-- Describe action to be performed
local function describe(action)
    if not action then action = {} end
    local o_o = action.o_o
    local p_o = action.pkg_old
    local o_n = action.o_n
    local p_n = action.pkg_new
    local a = action.action
    TRACE("DESCRIBE", a, o_o, o_n, p_o, p_n)
    if a then
        if a == "delete" then
            return string.format("De-install %s built from %s", p_o.name,
                                 o_o.name)
        elseif a == "change" then
            if p_o ~= p_n then
                local prev_origin =
                    o_o and o_o ~= o_n and " (was " .. o_o.name .. ")" or ""
                return string.format(
                           "Change package name from %s to %s for port %s%s",
                           p_o.name, p_n.name, o_n.name, prev_origin)
            else
                return string.format(
                           "Change origin of port %s to %s for package %s",
                           o_o.name, o_n.name, p_n.name)
            end
        elseif a == "exclude" then
            return string.format("Skip excluded package %s installed from %s",
                                 tostring(p_o), tostring(o_o))
        elseif a == "upgrade" then
            local from
            if p_n and p_n.pkgfile then
                from = "from " .. p_n.pkgfile
            else
                from = "using " .. o_n.name ..
                           (origin_changed(o_o, o_n) and " (was " .. o_o.name ..
                               ")" or "")
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
                        if vers_cmp == "<" then
                            verb = "Upgrade"
                        elseif vers_cmp == ">" then
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
    elseif not a then
        return "Keep " .. action.short_name
    end
    return "No action for " .. action.short_name
end

-- ----------------------------------------------------------------------------------
-- rename all matching package files (excluding package backups)
local function pkgfiles_rename(action) -- UNTESTED !!!
    local pkgname_new = action.pkg_new.name
    local pkgfiles = glob(action.pkg_old:filename {subdir = "*", ext = "t??"})
    for _, pkgfile_old in ipairs(pkgfiles) do
        if access(pkgfile_old, "r") and not strpfx(pkgfile_old, PATH.packages_backup) then
            local pkgfile_new = path_concat(dirname(pkgfile_old),
                                                pkgname_new .. pkgfile_old:gsub(".*(%.%w+)", "%1"))
            return Exec.run{"/bin/mv",
                as_root = true,
                to_tty = true,
                pkgfile_old,
                pkgfile_new
            }
        end
    end
end

-- ----------------------------------------------------------------------------------
-- convert origin with flavor to sub-directory name to be used for port options
-- move the options file if the origin of a port is changed
local function portdb_update_origin(action)
    local portdb_dir_old = action.o_o:portdb_path()
    if is_dir(portdb_dir_old) and access(portdb_dir_old .. "/options", "r") then
        local portdb_dir_new = action.o_n:portdb_path()
        if not is_dir(portdb_dir_new) then
            return Exec.run{"/bin/mv",
                as_root = true,
                to_tty = true,
                portdb_dir_old,
                portdb_dir_new
            }
        end
    end
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
    local pkgfile = action.pkg_new.pkg_filename -- (PATH.packages .. "All", pkgname, Options.package_format)
    TRACE("PACKAGE_CREATE", o_n, pkgname, pkgfile)
    if Options.skip_recreate_pkg and access(pkgfile, "r") then
        Msg.show {
            "A package file for", pkgname,
            "does already exist and will not be overwritten"
        }
    else
        Msg.show {"Create a package for new version", pkgname}
        local jailed = Options.jailed
        local as_root = PARAM.packages_ro
        local base = (as_root or jailed) and PATH.tmpdir or PATH.packages -- use random tempdir !!!
        local sufx = "." .. Options.package_format
        if o_n:port_make{
            jailed = jailed,
            to_tty = true,
            "_OPTIONS_OK=1",
            "PACKAGES=" .. base,
            "PKG_SUFX=" .. sufx,
            "package"
        } then
            if as_root or jailed then
                local tmpfile = path_concat(base, "All", pkgname .. sufx)
                if jailed then
                    tmpfile = path_concat(PARAM.jailbase, tmpfile)
                end
                chown(tmpfile, 0, 0)
                Exec.run {as_root = as_root, "/bin/mv", tmpfile, pkgfile}
            end
            assert(Options.dry_run or access(pkgfile, "r"),
                   "Package file has not been created")
            action.pkg_new:category_links_create(o_n.categories)
            Msg.show {"Package saved to", pkgfile}
        end
        return true
    end
end

-- clean work directory and special build depends (might also be delayed to just before program exit)
local function port_clean(action)
    local args = {
        to_tty = true,
        jailed = true,
        "NO_CLEAN_DEPENDS=1",
        "clean"
    }
    local o_n = action.o_n
    if not o_n:port_make(args) then
        return false
    end
    local special_depends = o_n.special_depends or {}
    for _, origin_target in ipairs(special_depends) do
        TRACE("PORT_CLEAN_SPECIAL_DEPENDS", o_n.name, origin_target)
        local target = target_part(origin_target)
        local origin = Origin.get(origin_target:gsub(":.*", ""))
        if target ~= "fetch" and target ~= "checksum" then
            return origin:port_make(args)
        end
    end
end

-- check conflicts of new port with installed packages (empty table if no conflicts found)
local function conflicting_pkgs(action, mode)
    local origin = action.o_n
    if origin and origin.build_conflicts and origin.build_conflicts[1] then
        local list = {}
        local make_target = mode == "build_conflicts" and
                                "check-build-conflicts" or "check-conflicts"
        local conflicts_table = origin:port_make{
            table = true,
            safe = true,
            make_target
        }
        if conflicts_table then
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

-- ----------------------------------------------------------------------------------
-- extract and patch files, but do not try to fetch any missing dist files
local function provide_special_depends(special_depends)
    TRACE("SPECIAL_DEPENDS", table.unpack(special_depends or {}))
    -- local special_depends = action.o_n.special_depends
    for _, origin_target in ipairs(special_depends) do
        -- print ("SPECIAL_DEPENDS", origin_target)
        local target = target_part(origin_target)
        local origin = Origin:new(origin_target:gsub(":.*", "")) -- define function to strip the target ???
        -- assert (origin:wait_checksum ())
        if target ~= "fetch" and target ~= "checksum" then
            -- extract from package if $target=stage and _packages is set? <se>
            local args = {
                to_tty = true,
                jailed = true,
                "NO_DEPENDS=1",
                "DEFER_CONFLICTS_CHECK=1",
                "DISABLE_CONFLICTS=1",
                "CMD.fetch=true",
                target
            }
            if not origin:port_make(args) then return false end
        end
    end
    return true
end

-- ----------------------------------------------------------------------------------
-- perform all steps required to build a port (extract, patch, build, stage, opt. package)
local function perform_portbuild(action)
    local o_n = action.o_n
    local pkgname_new = action.pkg_new.name
    local special_depends = o_n.special_depends
    TRACE("perform_portbuild", o_n.name, pkgname_new,
          table.unpack(special_depends or {}))
    if not Options.no_pre_clean then port_clean(action) end
    -- check for special license and ask user to accept it (may require make extract/patch)
    -- may depend on OPTIONS set by make configure
    if not PARAM.disable_licenses then
        if not o_n:check_license() then return false end
    end
    -- <se> VERIFY THAT ALL DEPENDENCIES ARE AVAILABLE AT THIS POINT!!!
    -- extract and patch the port and all special build dependencies ($make_target=extract/patch)
    TRACE("SPECIAL:", #special_depends, special_depends[1])
    if #special_depends > 0 then
        if not provide_special_depends(special_depends) then return false end
    end
    if not o_n:port_make{
        to_tty = true,
        jailed = true,
        "NO_DEPENDS=1",
        "DEFER_CONFLICTS_CHECK=1",
        "DISABLE_CONFLICTS=1",
        "FETCH=true",
        "patch"
    } then
	return false
    end
    --[[
    -- check whether build of new port is in conflict with currently installed version
    local deleted = {}
    local conflicts = check_build_conflicts (action)
    for i, pkg in ipairs (conflicts) do
	if pkg == pkgname_old then
	    -- ??? pkgname_old is NOT DEFINED
	    Msg.show {"Build of", o_n.name, "conflicts with installed package", pkg .. ", deleting old package"}
	    automatic = PkgDb.automatic_get (pkg)
	    table.insert (deleted, pkg)
	    perform_pkg_deinstall (pkg)
	    break
	end
    end
    --]]
    -- build and stage port
    if not o_n:port_make{
        to_tty = true,
        jailed = true,
        "NO_DEPENDS=1",
        "DISABLE_CONFLICTS=1",
        "_OPTIONS_OK=1",
        "build",
        "stage"
    } then
	return false
    end
    return true
end

-- de-install (possibly partially installed) port after installation failure
local function deinstall_failed(action)
    Msg.show {
        "Installation of", action.pkg_new.name,
        "failed, deleting partially installed package"
    }
    return action.o_n:port_make{
        to_tty = true,
        jailed = true,
        as_root = true,
        "deinstall"
    }
end

--
local function perform_provide(action)
    TRACE("PROVIDE", action.pkg_new.name)
    return action.pkg_new:install()
end

-- perform actual installation from a port or package
local function perform_installation(action)
    local o_n = action.o_n
    local p_o = action.pkg_old
    local p_n = action.pkg_new
    local pkgname_old = p_o and p_o.name
    local pkgname_new = p_n.name
    local o_n = o_n.name
    local pkgfile = p_n.pkgfile
    local pkg_msg_old
    -- prepare installation, if this is an upgrade (and not a fresh install)
    if pkgname_old then
        if not Options.jailed or PARAM.phase == "install" then
            -- keep old package message for later comparison with new message
            pkg_msg_old = p_o:message()
            -- create backup package file from installed files
            local create_backup = pkgname_old ~= pkgname_new or not pkgfile
            -- preserve currently installed shared libraries
            if Options.save_shared then
                p_o:shlibs_backup() -- OUTPUT
            end
            -- preserve pkg-static even when deleting the "pkg" package
            if action.o_n == "ports-mgmt/pkg" then
                Exec.run {as_root = true, "unlink", CMD.pkg .. "~"}
                Exec.run {as_root = true, "ln", CMD.pkg, CMD.pkg .. "~"}
            end
            -- delete old package version
            p_o:deinstall(create_backup) -- OUTPUT
            -- restore pkg-static if it has been preserved
            if o_n == "ports-mgmt/pkg" then
                Exec.run {as_root = true, "unlink", CMD.pkg}
                Exec.run {as_root = true, "mv", CMD.pkg .. "~", CMD.pkg}
            end
        end
    end
    if pkgfile then
        -- try to install from package
        Progress.show("Install", pkgname_new, "from a package")
        -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
        if not p_n:install() then
            -- OUTPUT
            if not Options.jailed then
                p_n:deinstall() -- OUTPUT
                if p_o then p_o:recover() end
            end
            Progress.show("Rename", pkgfile, "to",
                          pkgfile .. ".NOTOK after failed installation")
            os.rename(pkgfile, pkgfile .. ".NOTOK")
            return false
        end
    else
        -- try to install new port
        Progress.show("Install", pkgname_new, "built from", o_n)
        -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
        if not o_n:install() then
            -- OUTPUT
            deinstall_failed(action)
            if p_o then p_o:recover() end
            return false
        end
    end
    -- set automatic flag to the value the previous version had
    if p_o and p_o.is_automatic then p_n:automatic_set(true) end
    -- register package name if package message changed
    local pkg_msg_new = p_n:message()
    if pkg_msg_old ~= pkg_msg_new then
        action.pkgmsg = pkg_msg_new -- package message returned as field in action record ???
    end
    -- remove all shared libraries replaced by new versions from shlib backup directory
    if p_o and Options.save_shared then
        p_o:shlibs_backup_remove_stale() -- use action as argument???
    end
    -- delete stale package files
    if pkgname_old then
        if pkgname_old ~= pkgname_new then
            p_o:delete_old()
            if not Options.backup then p_o:backup_delete() end
        end
    end
    return true
end

-- install or upgrade a port
local function perform_install_or_upgrade(action)
    -- local o_n = action.o_n
    local p_n = action.pkg_new
    TRACE("P", p_n.name, p_n.pkgfile, table.unpack(table.keys(p_n)))
    -- has a package been identified to be used instead of building the port?
    local pkgfile
    -- CHECK CONDITION for use of pkgfile: if build_type ~= "force" and not Options.packages and (not Options.packages_build or dep_type ~= "build") then
    if true or not action.force and
        (Options.packages or Options.packages_build and not p_n.is_run_dep) then -- XXX TESTTESTTEST
        TRACE("P", p_n.name, p_n.pkgfile, table.unpack(table.keys(p_n)))
        pkgfile = p_n.pkgfile
        TRACE("PKGFILE", pkgfile)
    end
    local skip_install = (Options.skip_install or Options.jailed) and
                             not p_n.is_build_dep -- NYI: and BUILDDEP[o_n]
    local taskmsg = describe(action)
    Progress.show_task(taskmsg)
    -- if not installing from a package file ...
    local seconds
    if not pkgfile then
        -- assert (NYI: o_n:wait_checksum ())
        if not Options.fetch_only then
            seconds = os.time()
            if not perform_portbuild(action) then return false end
            -- create package file from staging area
            if Options.create_package then
                if not package_create(action) then
                    Msg.show {"Could not write package file for", p_n.name}
                    return false
                end
            end
        end
    end
    -- install build depends immediately but optionally delay installation of other ports
    if not skip_install then
        TRACE("PKGFILE2", pkgfile)
        if not perform_installation(action) then return false end
        --[[
      if not Options.jailed then
	 worklist_remove (o_n)
      end
      --]]
    end
    -- perform some book-keeping and clean-up if a port has been built
    if not pkgfile then
        -- preserve file names and hashes of distfiles from new port
        -- NYI distinfo_cache_update (o_n, pkgname_new)
        -- backup clean port directory and special build depends (might also be delayed to just before program exit)
        if not Options.no_post_clean then
            port_clean(action)
            -- delete old distfiles
            -- NYI distfiles_delete_old (o_n, pkgname_old) -- OUTPUT
            if seconds then seconds = os.time() - seconds end
        end
    end
    -- report success
    if not Options.dry_run then Msg.success_add(taskmsg, seconds) end
    return true
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
    return action.pkg_old:deinstall(Options.backup)
end

--[[
-- peform delayed installation of ports not required as build dependencies after all ports have been built
local function perform_delayed_installation(action)
    local p_n = action.pkg_new
    action.pkg_new.pkgfile = Package.filename {p_n}
    local taskmsg = describe(action)
    Progress.show_task(taskmsg)
    assert(perform_installation(action),
           "Installation of " .. p_n.name .. " from " .. pkgfile .. " failed")
    Msg.success_add(taskmsg)
end
--]]

-- ----------------------------------------------------------------------------------
local BUILDLOG = nil

-- delete obsolete packages
local function perform_delete(action)
    if perform_deinstall(action) then
        action.done = true
        return true
    end
end

-- update changed port origin in the package db and move options file
local function perform_origin_change(action)
    Progress.show("Change origin of", action.pkg_old.name, "from",
                  action.o_o.name, "to", action.o_n.name)
    if PkgDb.update_origin(action.o_o, action.o_n,
                           action.pkgname_old) then
        portdb_update_origin(action.o_o, action.o_n)
        action.done = true
        return true
    end
end

-- update package name of installed package
local function perform_pkg_rename(action)
    Progress.show("Rename", action.pkg_old.name, "to", action.pkg_new.name)
    if PkgDb.update_pkgname(action.pkg_old.name, action.pkg_new.name) then
        pkgfiles_rename(action)
        action.done = true
        return true
    end
end

-- ----------------------------------------------------------------------------------
local ACTION_LIST = {}

local function list()
   return ACTION_LIST
end

local function perform_upgrades()
    -- install or upgrade required packages
    for _, action in ipairs(ACTION_LIST) do
        Msg.show {start = true}
        -- if Options.hide_build is set the buildlog will only be shown on errors
        local o_n = rawget(action, "o_n")
        local is_interactive = o_n and o_n.is_interactive
        if Options.hide_build and not is_interactive then
            BUILDLOG = tempfile_create("BUILD_LOG")
        end
        local result
        local verb = action.action
        -- print ("DO", verb, action.pkg_new.name)
        if verb == "delete" then
            result = perform_delete(action)
        elseif verb == "upgrade" then
            result = perform_install_or_upgrade(action)
        elseif verb == "change" then
            if action.pkg_old.name ~= action.pkg_new.name then
                result = perform_pkg_rename(action)
            elseif action.o_o.name ~= action.o_n.name then
                result = perform_origin_change(action)
            end
        elseif verb == "provide" or verb == false then
            if Options.jailed then
                if action.pkg_new.pkgfile then
                    result = perform_provide(action)
                else
                    result = perform_install_or_upgrade(action)
                end
            else
                result = true -- nothing to be done
            end
        elseif verb == "exclude" then
            result = true -- do nothing
        else
            error("unknown verb in action: " .. (verb or "<nil>"))
        end
        if result then
            if BUILDLOG then
                tempfile_delete("BUILD_LOG")
                BUILDLOG = nil
            end
            -- NYI: o_n:perform_post_build_deletes ()
        else
            return false
        end
    end
    return true
end

-- update repository database after creation of new packages
local function perform_repo_update()
    -- create repository database
    Msg.show {start = true, "Create local package repository database ..."}
    Exec.pkg {as_root = true, "repo", PATH.packages .. "All"}
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
                if Msg.read_yn("y", "Package " .. pkgname ..
                                   " was installed as a dependency and does not seem to used anymore, delete") then
                    Package.perform_deinstall(pkgname)
                else
                    if Msg.read_yn("y", "Mark " .. pkgname ..
                                       " as 'user installed' to protect it against automatic deletion") then
                        PkgDb.automatic_set(pkgname, false)
                    end
                end
            end
        end
    end
end

-- return the sum of the numbers of required operations
function tasks_count() return #ACTION_LIST end

-- display statistics of actions to be performed
local function show_statistics()
    -- create statistics line from parameters
    local NUM = {}
    local function format_install_msg(num, actiontext)
        if num and num > 0 then
            local plural_s = num ~= 1 and "s" or ""
            return string.format("%5d %s%s %s", num, "package", plural_s,
                                 actiontext)
        end
    end
    local function count_actions()
        local function incr(field) NUM[field] = (NUM[field] or 0) + 1 end
        for _, v in ipairs(ACTION_LIST) do
            local a = v.action
            if a == "upgrade" then
                local p_o = v.pkg_old
                local p_n = v.pkg_new
                if p_o == p_n then
                    incr("reinstalls")
                elseif p_o == nil then
                    incr("installs")
                else
                    incr("upgrades")
                end
            elseif a == "delete" then
                incr("deletes")
            elseif a == "change" then
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
        count_actions(ACTION_LIST)
        Msg.show {start = true, "Statistic of planned actions:"}
        local txt = format_install_msg(NUM.deletes, "will be deleted")
        if txt then Msg.show {txt} end
        txt = format_install_msg(NUM.moves,
                                 "will be changed in the package registry")
        if txt then Msg.show {txt} end
        -- Msg.cont (0, format_install_msg (NUM.provides, "will be loaded as build dependencies"))
        -- if txt then Msg.cont (0, txt) end
        -- Msg.cont (0, format_install_msg (NUM.builds, "will be built"))
        -- if txt then Msg.cont (0, txt) end
        txt = format_install_msg(NUM.reinstalls, "will be " .. reinstalled_txt)
        if txt then Msg.show {txt} end
        txt = format_install_msg(NUM.installs, "will be " .. installed_txt)
        if txt then Msg.show {txt} end
        txt = format_install_msg(NUM.upgrades, "will be upgraded")
        if txt then Msg.show {txt} end
        Msg.show {start = true}
    end
end

--
local function execute()
    if tasks_count() == 0 then
        -- ToDo: suppress if updates had been requested on the command line
        Msg.show {start = true, "No installations or upgrades required"}
    else
        -- all fetch distfiles tasks should have been requested by now
        Distfile.fetch_finish()
        -- display list of actions planned
        -- NYI register_delete_build_only ()

        show_statistics()
        if Options.fetch_only then
            if Msg.read_yn(
                "Fetch and check distfiles required for these upgrades now?",
                "y") then
                -- wait for completion of fetch operations
                -- perform_fetch_only () -- NYI wait for completion of fetch operations
            end
        else
            Progress.clear()
            if Msg.read_yn("Perform these upgrades now?", "y") then
                -- perform the planned tasks in the order recorded in ACTION_LIST
                Msg.show {start = true}
                Progress.set_max(tasks_count())
                --
                if Options.jailed then Jail.create() end
                if not perform_upgrades() then
                  if Options.hide_build then
                  -- shell_pipe ("cat > /dev/tty", BUILDLOG) -- use read and write to copy the file to STDOUT XXX
                  end
                  fail("Port upgrade failed.")
                end
                if Options.jailed then Jail.destroy() end
                Progress.clear()
                if Options.repo_mode then
                    perform_repo_update()
                else
                    -- XXX fold into perform_upgrades()???
                    -- new action verb required???
                    -- or just a plain install from package???)
                    --[[
                    if #DELAYED_INSTALL_LIST > 0 then -- NYI to be implemented in a different way
                        PARAM.phase = "install"
                        perform_delayed_installations()
                    end
                    --]]
                end
            end
            if tasks_count() == 0 then
                Msg.show {
                    start = true,
                    "All requested actions have been completed"
                }
            end
            Progress.clear()
            PARAM.phase = ""
        end
    end
    return true
end

--
local function determine_pkg_old(action, k)
    local pt = action.o_o and action.o_o.old_pkgs
    if pt then
        local pkg_new = action.pkg_new
        if pkg_new then
            local pkgnamebase = pkg_new.name_base
            for p, _ in ipairs(pt) do
                if p.name_base == pkgnamebase then return p end
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
    local o = action.pkg_old and rawget(action.pkg_old, "origin") or
                  action.pkg_new and action.pkg_new.origin -- NOT EXACT
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
        if mo and mo.reason or verify_origin(mo) then return mo end
        if verify_origin(o) then return o end
    end
end

--
local function compare_versions(action, k)
    local p_o = action.pkg_old
    local p_n = action.pkg_new
    if p_o and p_n then
        if p_o == p_n then return "=" end
        return Exec.pkg {safe = true, "version", "-t", p_o.name, p_n.name} -- could always return "<" for speed ...
    end
end

--
local function determine_action(action, k)
    local p_o = action.pkg_old
    local o_n = action.o_n
    local o_o = action.o_o
    local p_n = action.pkg_new
    local function need_upgrade()
        if Options.force or action.build_type == "provide" or action.build_type ==
            "checkabi" or rawget(action, "force") then
            return true -- add further checks, e.g. changed dependencies ???
        end
        if not o_o or o_o.flavor ~= o_n.flavor then return true end
        if p_o == p_n then return false end
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

    if excluded() then
        return "exclude"
    elseif not p_n then
        return "delete"
    elseif not p_o or need_upgrade() then
        return "upgrade"
    elseif p_o ~= p_n or origin_changed(o_o, o_n) then
        return "change"
    end
    return false
end

--
ACTION_CACHE = {}

local function clear_cached_action(action)
    local pkg_old = action.pkg_old
    local pkg_new = action.pkg_new
    if action.action == "delete" then
        if ACTION_CACHE[pkg_old] then ACTION_CACHE[pkg_old.name] = nil end
    end
    if ACTION_CACHE[pkg_new] then ACTION_CACHE[pkg_new.name] = nil end
end

local function set_cached_action(action)
    local function check_and_set(field)
        local v = rawget(action, field)
        if v then
            local n = v.name
            if n and n ~= "" then
                if ACTION_CACHE[n] and ACTION_CACHE[n] ~= action then
                    -- error ()
                    TRACE("SET_CACHED_ACTION_CONFLICT",
                          describe(ACTION_CACHE[n]), describe(action))
                end
                ACTION_CACHE[n] = action
                TRACE("SET_CACHED_ACTION", field, n)
            else
                error("Empty package name " .. field .. " " .. describe(action))
            end
        end
    end
    assert(action, "set_cached_action called with nil argument")
    TRACE("SET_CACHED_ACTION", describe(action))
    check_and_set("pkg_old")
    if action.action ~= "delete" then check_and_set("pkg_new") end
    return action
end

--
local function get_pkgname(action)
    if action.pkg_old and action.action == "delete" then
        return action.pkg_old.name
    elseif action.pkg_new then
        return action.pkg_new.name
    end
end

--
local function fixup_conflict(action1, action2)
    TRACE("FIXUP", action1.action, action2.action)
    if action2.action and
        (not action1.action or action1.action > action2.action) then
        action1, action2 = action2, action1 -- normalize order: action1 < action2 or action2 == nil
    end
    local pkgname = get_pkgname(action1) or get_pkgname(action2)
    local a1 = action1.action
    local a2 = action2.action
    if a1 == "upgrade" then
        if not a2 then -- attempt to upgrade some port to already existing package
            TRACE("FIXUP_CONFLICT1", describe(action1))
            TRACE("FIXUP_CONFLICT2", describe(action2))
            action1.action = "delete"
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
                    if v1 and not v2 then action2[k] = v1 end
                end
                action1.action = nil
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
    error("Duplicate actions for " .. pkgname .. ":\n#	1) " ..
              (action1 and describe(action1) or "") .. "\n#	2) " ..
              (action2 and describe(action2) or ""))
end

-- object that controls the upgrading and other changes
local function cache_add(action)
    local pkgname = get_pkgname(action)
    local action0 = ACTION_CACHE[pkgname]
    if action0 and action0 ~= action then
        clear_cached_action(action)
        clear_cached_action(action0)
        fixup_conflict(action, action0) -- re-register in ACTION_CACHE after fixup???
        error("Duplicate actions resolved for " .. pkgname .. ":\n#	1) " ..
                  (action and describe(action) or "") .. "\n#	2) " ..
                  (action0 and describe(action0) or ""))
        set_cached_action(action0)
    end
    return set_cached_action(action)
end

--
local function lookup_cached_action(args) -- args.pkg_new is a string not an object!!
    local action
    local p_o = rawget(args, "pkg_old")
    local p_n = rawget(args, "pkg_new") or rawget(args, "o_n") and
                    args.o_n.pkg_new
    action = p_n and ACTION_CACHE[p_n.name] or p_o and ACTION_CACHE[p_o.name]
    TRACE("CACHED_ACTION", args.pkg_new, args.pkg_old,
          action and action.pkg_new and action.pkg_new.name,
          action and action.pkg_old and action.pkg_old.name, "END")
    return action
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
        return try_origin(action.o_o) or
                   try_origin(determine_o_n(action))
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
    if action.o_o and action.o_o:check_excluded() or
        action.o_n and action.o_n:check_excluded() or
        action.pkg_new and action.pkg_new:check_excluded() then
        action.action = "exclude"
        return action
    end
    --
    local origin = action.o_n
    if origin then origin:check_config_allow(rawget(action, "recursive")) end

    TRACE("CHECK_PKG_OLD_o_o", action.o_o, action.pkg_old,
          action.o_n, action.pkg_new)
    if not action.pkg_old and action.o_o and action.pkg_new then
        local pkg_name = chomp(PkgDb.query {"%n-%v", action.pkg_new.name_base})
        TRACE("PKG_NAME", pkg_name)
        if pkg_name then action.pkg_old = Package:new(pkg_name) end
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
local function sort_list()
    local max_str = tostring(#ACTION_LIST)
    local sorted_list = {}
    local function add_action(action)
        if not rawget(action, "planned") then
            local deps = rawget(action, "build_depends")
            if deps then
                for _, o in ipairs(deps) do
                    local origin = Origin.get(o)
                    local pkg_new = origin.pkg_new
                    local a = rawget(ACTION_CACHE, pkg_new.name)
                    TRACE("BUILD_DEP", a and rawget(a, "action"), origin.name,
                          origin.pkg_new, origin.pkg_new and
                              rawget(origin.pkg_new, "is_installed"))
                    -- if a and not rawget (a, "planned") then
                    if a and not rawget(a, "planned") and
                        not rawget(origin.pkg_new, "is_installed") then
                        add_action(a)
                    end
                end
            end
            assert(not rawget(action, "planned"),
                   "Dependency loop for: " .. describe(action))
            table.insert(sorted_list, action)
            action.listpos = #sorted_list
            action.planned = true
            Msg.show {
                "[" .. tostring(#sorted_list) .. "/" .. max_str .. "]",
                tostring(action)
            }
            --
            local deps = rawget(action, "run_depends")
            if deps then
                for _, o in ipairs(deps) do
                    local origin = Origin.get(o)
                    local pkg_new = origin.pkg_new
                    local a = rawget(ACTION_CACHE, pkg_new.name)
                    TRACE("RUN_DEP", a and rawget(a, "action"), origin.name,
                          origin.pkg_new, origin.pkg_new and
                              rawget(origin.pkg_new, "is_installed"))
                    -- if a and not rawget (a, "planned") then
                    if a and not rawget(a, "planned") and
                        not rawget(origin.pkg_new, "is_installed") then
                        add_action(a)
                    end
                end
            end
        end
    end

    Msg.show {start = true, "Sort", #ACTION_LIST, "actions"}
    for i, a in ipairs(ACTION_LIST) do
        Msg.show {start = true}
        add_action(a)
    end
    -- assert (#ACTION_LIST == #sorted_list, "ACTION_LIST items have been lost: " .. #ACTION_LIST .. " vs. " .. #sorted_list)
    ACTION_LIST = sorted_list
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
    Msg.show {start = true}
    for i, a in ipairs(ACTION_LIST) do
        local o = rawget(a, "o_n")
        if o and rawget(o, "license") then
            if not check_accepted(o.license) then
                Msg.show {"Check license for", o.name, table.unpack(o.license)}
                -- o:port_make {"-DDEFER_CONFLICTS_CHECK", "-DDISABLE_CONFLICTS", "extract", "ask-license", accepted_opt}
                -- o:port_make {"clean"}
                set_accepted(o.license)
            end
        end
    end
end

--
local function port_options()
    Msg.show {level = 2, start = true, "Check for new port options"}
    for i, a in ipairs(ACTION_LIST) do
        local o = rawget(a, "o_n")
        -- if o then print ("O", o, o.new_options) end
        if o and rawget(o, "new_options") then
            Msg.show {
                "Set port options for", rawget(o, "name"),
                table.unpack(rawget(o, "new_options"))
            }
        end
    end
    Msg.show {
        level = 2,
        start = true,
        "Check for new port options has completed"
    }
end

--
local function check_conflicts(mode)
    Msg.show {
        level = 2,
        start = true,
        "Check for conflicts between requested updates and installed packages"
    }
    for _, action in ipairs(ACTION_LIST) do
        local o_n = rawget(action, "o_n")
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

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache()
    local t = ACTION_CACHE
    for _, v in ipairs(table.keys(t)) do
        local name = tostring(v)
        TRACE("ACTION_CACHE", name, table.unpack(table.keys(t[v])))
    end
end

-- ----------------------------------------------------------------------------------
local function __newindex(action, n, v)
    TRACE("SET(a)",
          rawget(action, "pkg_new") and action.pkg_new.name or
              rawget(action, "pkg_old") and action.pkg_old.name, n, v)
    if v and (n == "pkg_old" or n == "pkg_new") then
        ACTION_CACHE[v.name] = action
    end
    rawset(action, n, v)
end

local function __index(action, k)
    local function __depends(action, k)
        local o_n = action.o_n
        TRACE("DEP_REF", k, o_n and table.unpack(o_n[k]) or nil)
        if o_n then
            return o_n[k]
            -- k = string.match (k, "[^_]+")
            -- return o_n.depends (action.o_n, k)
        end
    end
    local function __short_name(action, k)
        return action.pkg_new and action.pkg_new.name or action.pkg_old and
                   action.pkg_old.name or action.o_n and
                   action.o_n.name or action.o_o and
                   action.o_o.name or "<unknown>"
    end
    local dispatch = {
        pkg_old = determine_pkg_old,
        pkg_new = determine_pkg_new,
        vers_cmp = compare_versions,
        o_o = determine_o_o,
        o_n = determine_o_n,
        build_depends = __depends,
        run_depends = __depends,
        action = determine_action,
        short_name = __short_name
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
    __tostring = describe
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
                    action.action = "delete"
                    args.pkg_new = nil
                    args.o_n = nil
                end
                action.pkg_old = args.pkg_old
            end
            if args.pkg_new then
                if rawget(action, "pkg_new") then
                    assert(action.pkg_new.name == args.pkg_new.name,
                           "Conflicting pkg_new: " .. action.pkg_new.name ..
                               " vs. " .. args.pkg_new.name)
                else
                    action.pkg_new = args.pkg_new
                end
            end
            if args.o_n then
                if rawget(action, "o_n") then
                    assert(action.o_n.name == args.o_n.name,
                           "Conflicting o_n: " .. action.o_n.name ..
                               " vs. " .. args.o_n.name)
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
            if action.action == "exclude" then
                if action.o_n then
                    action.o_n:delete() -- remove this origin from ORIGIN_CACHE
                end
                args.recursive = true -- prevent endless config loop
                return new(Action, args)
            end
        end
        if action.action and action.action ~= "exclude" then
            if not rawget(action, "listpos") then
                table.insert(ACTION_LIST, action)
                action.listpos = #ACTION_LIST
                Progress.show_task(describe(action))
            end
            if action.action == "upgrade" then
                action.o_n:checksum()
            end
        end
        return cache_add(action)
    else
        error("Action:new() called with nil argument")
    end
end

-- ----------------------------------------------------------------------------------
--
return {
    new = new,
    execute = execute,
    packages_delete_stale = packages_delete_stale,
    --register_delayed_installs = register_delayed_installs,
    sort_list = sort_list,
    check_licenses = check_licenses,
    check_conflicts = check_conflicts,
    port_options = port_options,
    dump_cache = dump_cache,
    list = list,
    tasks_count = tasks_count,
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
