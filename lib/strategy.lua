#!/usr/local/bin/lua53

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
local Action = require("portmaster.action")
local Msg = require("portmaster.msg")
local Options = require("portmaster.options")
local Jail = require("portmaster.jail")
local Progress = require("portmaster.progress")
local Distfile = require("portmaster.distfiles")
local Exec = require("portmaster.exec")
local PkgDb = require("portmaster.pkgdb")

-------------------------------------------------------------------------------------
local P_US = require("posix.unistd")
local access = P_US.access

--
local function add_action (args)
    --Action:new(args)
    Exec.spawn(Action.new, Action, args)
    TRACE ("ADD_ACTION_SPAWNED", table.keys(args))
end

--
local function add_missing_deps(action_list)
    for i, a in ipairs(action_list) do
        if a.pkg_new and rawget(a.pkg_new, "is_installed") then
            -- print (a, "is already installed")
        else
            local add_dep_hdr = "Add build dependencies of " .. a.short_name
            local deps = a.build_depends or {} -- rename build_depends --> depends.build
            for _, dep in ipairs(deps) do
                local o = Origin:new(dep)
                local p = o.pkg_new
                if not Action.get(p.name) then
                    if add_dep_hdr then
                        Msg.show {level = 2, start = true, add_dep_hdr}
                        add_dep_hdr = nil
                    end
                    -- local action = Action:new {build_type = "auto", dep_type = "build", o_n = o}
                    local action = Action:new{build_type = "auto", dep_type = "build", pkg_new = p, o_n = o}
                    p.is_build_dep = true
                    -- assert (not o.action)
                    -- o.action = action -- NOT UNIQUE!!!
                end
            end
            add_dep_hdr = "Add run dependencies of " .. a.short_name
            deps = a.run_depends or {}
            for _, dep in ipairs(deps) do
                local o = Origin:new(dep)
                local p = o.pkg_new
                if not Action.get(p.name) then
                    if add_dep_hdr then
                        Msg.show {level = 2, start = true, add_dep_hdr}
                        add_dep_hdr = nil
                    end
                    -- local action = Action:new {build_type = "auto", dep_type = "run", o_n = o}
                    local action = Action:new{build_type = "auto", dep_type = "run", pkg_new = p, o_n = o}
                    p.is_run_dep = true
                    -- assert (not o.action)
                    -- o.action = action -- NOT UNIQUE!!!
                end
            end
        end
    end
    return action_list
end

--
local function sort_list(action_list) -- remove ACTION_CACHE from function arguments !!!
    local max_str = tostring(#action_list)
    local sorted_list = {}
    local function add_deps(action)
        local function add_dep_type(type)
            local deps = rawget(action, type .. "_depends")
            if deps then
                for _, o in ipairs(deps) do
                    local origin = Origin.get(o)
                    local pkg_new = origin.pkg_new
                    local a = Action.get(pkg_new.name)
                    TRACE("ADD_DEPS", type, a and rawget(a, "action"), origin.name, origin.pkg_new,
                          origin.pkg_new and rawget(origin.pkg_new, "is_installed"))
                    -- if a and not rawget (a, "planned") then
                    if a and not rawget(a, "planned") and not rawget(origin.pkg_new, "is_installed") then
                        add_deps(a)
                    end
                end
            end
        end
        if not rawget(action, "planned") then
            add_dep_type("build")
            assert(not rawget(action, "planned"), "Dependency loop for: " .. action:describe())
            table.insert(sorted_list, action)
            action.listpos = #sorted_list
            action.planned = true
            Msg.show {"[" .. tostring(#sorted_list) .. "/" .. max_str .. "]", tostring(action)}
            add_dep_type("run")
        end
    end

    Msg.show {start = true, "Sort", #action_list, "actions"}
    for _, a in ipairs(action_list) do
        Msg.show {start = true}
        add_deps(a)
    end
    -- assert (#action_list == #sorted_list, "action_list items have been lost: " .. #action_list .. " vs. " .. #sorted_list)
    return sorted_list
end

--
local function ports_update(filters)
    local pkgs, rest = Package:installed_pkgs(), {}
    for _, filter in ipairs(filters) do
        for _, pkg in ipairs(pkgs) do
            local selected, force = filter(pkg)
            if selected then
                add_action{build_type = "user", dep_type = "run", force = force, pkg_old = pkg}
            else
                table.insert(rest, pkg)
            end
        end
        pkgs, rest = rest, {}
    end
end

-- add all matching ports identified by pkgnames and/or portnames with optional flavor
local function add_multiple(args)
    local pattern_table = {}
    for _, name_glob in ipairs(args) do
        local pattern = string.gsub(name_glob, "%.", "%%.")
        pattern = string.gsub(pattern, "%?", ".")
        pattern = string.gsub(pattern, "%*", ".*")
        table.insert(pattern_table, "^(" .. pattern .. ")")
    end
    local function filter_match(pkg)
        for _, v in ipairs(pattern_table) do
            if string.match(pkg.name_base, v .. "$") then
                return true
            end
            if pkg.origin and (string.match(pkg.origin.name, v .. "$") or string.match(pkg.origin.name, v .. "@%S+$")) then
                return true
            end
        end
    end
    TRACE("PORTS_ADD_MULTIPLE-<", table.unpack(args))
    TRACE("PORTS_ADD_MULTIPLE->", table.unpack(pattern_table))
    ports_update {filter_match}
    for _, v in ipairs(args) do
        if string.match(v, "/") and access(path_concat(PATH.portsdir, v, "Makefile"), "r") then
            local o = Origin:new(v)
            local p = o.pkg_new
            Action:new{build_type = "user", dep_type = "run", force = Options.force, o_n = o, pkg_new = p}
        end
    end
    --[[
   for i, name_glob in ipairs (args) do
      local filenames = glob (path_concat (PATH.portsdir, name_glob, "Makefile"))
      if filenames then
	 for j, filename in ipairs (filenames) do
	    if access (filename, "r") then
	       local port = string.match (filename, "/([^/]+/[^/]+)/Makefile")
	       local origin = Origin:new (port)
	       Action:new {build_type = "user", dep_type = "run", o_n = origin}
	    end
	 end
      else
	 error ("No ports match " .. name_glob)
      end
   end
   --]]
end

-- process all outdated ports (may upgrade, install, change, or delete ports)
-- process all ports with old ABI or linked against outdated shared libraries
local function add_all_outdated()
    local current_libs = {}
    -- filter return values are: match, force
    local function filter_old_abi(pkg)
        return pkg.abi ~= PARAM.abi and pkg.abi ~= PARAM.abi_noarch, false -- true XXX
    end
    local function filter_old_shared_libs(pkg)
        if pkg.shared_libs then
            for lib, v in pairs(pkg.shared_libs) do
                return not current_libs[lib], true
            end
        end
    end
    local function filter_is_required(pkg)
        return not pkg.is_automatic or pkg.num_depending > 0, false
    end
    local function filter_pass_all()
        return true, false
    end

    for _, lib in ipairs(PkgDb.query {table = true, "%b"}) do
        current_libs[lib] = true
    end
    ports_update {
        filter_old_abi, -- filter_old_shared_libs,
        filter_is_required, filter_pass_all,
    }
end

--
local function perform_actions(action_list)
    if tasks_count() == 0 then
        -- ToDo: suppress if updates had been requested on the command line
        Msg.show {start = true, "No installations or upgrades required"}
    else
        -- all fetch distfiles tasks should have been requested by now
        Distfile.fetch_finish()
        -- display list of actions planned
        -- NYI register_delete_build_only ()

        Action.show_statistics(action_list)
        if Options.fetch_only then
            if Msg.read_yn("Fetch and check distfiles required for these upgrades now?", "y") then
                -- wait for completion of fetch operations
                -- perform_fetch_only () -- NYI wait for completion of fetch operations
            end
        else
            Progress.clear()
            if Msg.read_yn("Perform these upgrades now?", "y") then
                -- perform the planned tasks in the order recorded in action_list
                Msg.show {start = true}
                Progress.set_max(tasks_count())
                --
                if Options.jailed then
                    Jail.create()
                end
                if not Action.perform_upgrades(action_list) then
                    if Options.hide_build then
                        -- shell_pipe ("cat > /dev/tty", BUILDLOG) -- use read and write to copy the file to STDOUT XXX
                    end
                    fail("Port upgrade failed.")
                end
                if Options.jailed then
                    Jail.destroy()
                end
                Progress.clear()
                if Options.repo_mode then
                    Action.perform_repo_update()
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
                Msg.show {start = true, "All requested actions have been completed"}
            end
            Progress.clear()
            PARAM.phase = ""
        end
    end
    return true
end

local function execute()
    -- wait for all spawned tasks to complete
    Exec.finish_spawned(Action.new)

    -- add missing dependencies
    local action_list = add_missing_deps(Action.list())

    -- sort actions according to registered dependencies
    action_list = sort_list(action_list)

    --[[
   -- DEBUGGING!!!
   Origin.dump_cache ()
   Package.dump_cache ()
   Action.dump_cache ()
   --]]

    -- end of scan phase, all required actions are known at this point, builds may start
    PARAM.phase = "build"

    perform_actions(action_list)
end

return {
    add_multiple= add_multiple,
    add_all_outdated = add_all_outdated,
    execute = execute,
}

--[[
Concept for parallel port building:

    Build and/or install port:
        spawn one task per package to be generated or port to be installed:
            check_distfiles()
            wait until all distfiles are available or the fetch tasks has given up
            if fetching failed for at least 1 file:
                goto Abort
            -- all distfiles have been fetched
            wait for and provide build dependencies (including special dependencies, from port or package)
            if build dependencies are marked as failed (un-buildable):
                goto Abort
            -- all build dependencies have been provided (in base or jail)
            build port
            if the port build fails then
                goto Abort
            -- the port has been built and installed into the staging area
            create package (if requested)
            install port to the base system (if immediate installation has been requested):
                if install conflicts are to be expected (reported based on Makefile)
                    create package (unless already done)
                    record for delayed installation of the package and exit with success status
                try to provide all run dependencies
                if some run dependency is missing:
                    mark package as available (as dependency of other ports, i.e. to prevent dependency loops)
                    wait for all run dependencies to become available
                    if some run dependency could not be provided
                        goto Abort
                create backup package
                if the backup package cannot be created then
                    goto Abort
                deinstall old version
                if deinstallation fails
                    goto Abort
                install new version from staging area
                if installation fails
                    if failure is not due to install conflict detected only at that time
                        move new package file to .NOTOK name
                    re-install old version of package from saved backup file
                    goto Abort
            mark package as available (as dependency of other ports or for later installation to the base system)
            delete backup package (if requested not to be kept)

    Final:
        if ports have been selected for delayed installation:
            install missing packages -> Install from package
        remove build-only dependencies (if requested)

    Install from package:
        wait for package to become available
        if the package could not be provided (e.g. failed to build)
            goto Abort
        try to provide all run dependencies
        if some run dependency could not be provided
            goto Abort
        create backup package
        if the backup package cannot be created then
            goto Abort
        deinstall old version
        if deinstallation fails
            goto Abort
        install new version from package
        if installation fails
            move new package file to .NOTOK name
            re-install old version of package from saved backup file
            goto Abort
        delete backup package (if requested not to be kept)

    Abort:
        mark as un-buildable (with reason provided by failed function)
        signal task has completed (with error)
        exit task
--]]
