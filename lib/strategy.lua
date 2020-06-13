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
    local start_elem = 1
    while start_elem <= #action_list do
        local dep_ports = {}
        local last_elem = #action_list
        for i = start_elem, last_elem do
            local a = action_list[i]
            TRACE("ADD_MISSING_DEPS", i, #action_list)
            if a.pkg_new and rawget(a.pkg_new, "is_installed") then
                -- print (a, "is already installed")
            else
                local add_dep_hdr = "Add build dependencies of " .. a.short_name
                local deps = a.build_depends or {} -- rename build_depends --> depends.build
                for _, dep in ipairs(deps) do
                    local o = Origin:new(dep)
                    local p = o.pkg_new
                    if not Action.get(p.name) and not dep_ports[dep] then
                        if add_dep_hdr then
                            Msg.show {level = 2, start = true, add_dep_hdr}
                            add_dep_hdr = nil
                        end
                        dep_ports[dep] = true
                        add_action{build_type = "auto", dep_type = "build", pkg_new = p, o_n = o}
                        p.is_build_dep = true
                    end
                end
                add_dep_hdr = "Add run dependencies of " .. a.short_name
                deps = a.run_depends or {}
                for _, dep in ipairs(deps) do
                    local o = Origin:new(dep)
                    local p = o.pkg_new
                    if not Action.get(p.name) and not dep_ports[dep] then
                        if add_dep_hdr then
                            Msg.show {level = 2, start = true, add_dep_hdr}
                            add_dep_hdr = nil
                        end
                        dep_ports[dep] = true
                        add_action{build_type = "auto", dep_type = "run", pkg_new = p, o_n = o}
                        p.is_run_dep = true
                    end
                end
            end
        end
        Exec.finish_spawned(Action.new)
        start_elem = last_elem + 1
    end
end

--
local function sort_list(action_list) -- remove ACTION_CACHE from function arguments !!!
    local max_str = tostring(#action_list)
    local sorted_list = {}
    local function add_deps(action)
        local function add_deps_of_type(type)
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
            add_deps_of_type("build")
            assert(not rawget(action, "planned"), "Dependency loop for: " .. action:describe())
            table.insert(sorted_list, action)
            action.listpos = #sorted_list
            action.planned = true
            Msg.show {"[" .. tostring(#sorted_list) .. "/" .. max_str .. "]", tostring(action)}
            add_deps_of_type("run")
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
    local function load_current_libs()
        local t = {}
        for _, lib in ipairs(PkgDb.query {table = true, "%b"}) do
            t[lib] = true
        end
        return t
    end
    -- filter return values are: match, force
    local function filter_old_abi(pkg)
        return pkg.abi ~= PARAM.abi and pkg.abi ~= PARAM.abi_noarch, false -- true XXX
    end
    local current_libs
    local function filter_old_shared_libs(pkg)
        if pkg.shared_libs then
            current_libs = current_libs or load_current_libs()
            for i, lib in pairs(pkg.shared_libs) do
                TRACE("CHECK_CURRENT_LIBS", lib, current_libs[lib])
                if not current_libs[lib] then
                    TRACE("OLD_LIB", lib)
                    return true, true
                end
            end
        end
    end
    local function filter_is_required(pkg)
        return not pkg.is_automatic or pkg.num_depending > 0, false
    end
    local function filter_pass_all()
        return true, false
    end

    ports_update {
        filter_old_abi,
        --filter_old_shared_libs, -- currently a NOP since both sets of libraries are obtained with pkg query %b
        filter_is_required,
        filter_pass_all,
    }
end

--
local function perform_actions(action_list)
    if tasks_count() == 0 then
        -- ToDo: suppress if no updates had been requested on the command line
        Msg.show {start = true, "No installations or upgrades required"}
    else
        Action.show_statistics(action_list)
        if Options.fetch_only then
            if Msg.read_yn("Fetch and check distfiles required for these upgrades now?", "y") then
                Distfile.fetch_finish()
                --check_fetch_success() -- display list of missing or wrong distfiles, if any
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

    -- cache local reference to ACTION_LIST
    local action_list = Action.list()

    -- add missing dependencies
    add_missing_deps(action_list)

    -- sort actions according to registered dependencies
    action_list = sort_list(action_list)

    --[[ DEBUGGING ONLY!!!
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

Locks:
    1) FetchLock
    2) PackageLock
    3) WorkLock

    No parallel build within a port if either of the following is defined:
        DISABLE_MAKE_JOBS -- User variable?
        MAKE_JOBS_UNSAFE -- Makefile variable?
        NO_BUILD -- No build phase

--> Fetch and check distfiles: -- implements check_distfiles()
EL1+    acquire exclusive lock(s) on distfile name(s) to protect fetching of distfile(s) to collide
        if distfiles have not been previously fetched and verified
            invoke "make checksum" to fetch and check distfiles
            record checksum result (success/fail) in global status array
EL1-    release exclusive lock(s) on distfile name(s)

--> Build port:
EL2+    acquire exclusive lock (on the package name that is to be generated) -- possibly with limit on number of locks
SL1+    use shared lock to wait until all distfiles are available or the fetch task has given up
SL1-    release lock since distfiles are not expected to vanish once they are there
        if fetching failed for at least 1 file:
            goto Abort
        -- all distfiles have been fetched
        -- wait for build dependencies to become available
SL2+    use shared lock on package names of build dependencies to wait for and provide build dependencies (including special dependencies, from port or package)
        -- build dependencies that have not been updated must block the provide operation!
        -- run dependencies of build dependencies are considered build dependencies, here!
        if build dependencies are marked as failed (unbuildable):
            goto Abort
        -- all build dependencies have been provided (in base or jail)
        -- all build dependencies have been (share) locked to prevent de-installation before the port has been built
EL3+    acquire exclusive lock on work directory for port and all special_depends
        -- prevent parallel builds of the same port, e.g. of different flavors
        -- pass weight for the expected number of parallel processes (half the number of cores/threads by default?)
        build port
        -- port has been built and can be packaged or installed
SL2-    release shared locks on build dependencies (only required to allow freeing of memory for locks)
        if the port build failed then
            goto Abort
        -- the port has been built and temporarily installed into the staging area
        create package (if requested)

--> Install port to the base system (from build directory):
        if install conflicts are to be expected (reported based on Makefile)
            create package (unless already done)
            record for delayed installation of the package
            exit with success status
(SL2+)  try to provide all run dependencies (wait for them to become available by acquiring shared locks on them)
        if some run dependency is missing:
(EL2-)      mark the just created package as available (as dependency of other ports, to prevent dependency loops)
SL2+        use shared lock to wait for all run dependencies to become available
            if some run dependency could not be provided (failed to build)
                goto Abort
        if jailed or repo-mode then
            spawn delete task for this package and all its run dependencies (will be blocked)
        -- create backup package and deinstall old version
        create backup package
        if the backup package cannot be created then
            goto Abort
        deinstall old version
        if deinstallation fails
            goto Abort
        -- ready to install
        install new version from staging area
        if installation fails
            if failure is not due to install conflict detected only at that time
                move new package file to .NOTOK name
            re-install old version of package from saved backup file
            goto Abort
        -- release work directory
EL3-    release locks on work directories

--> Provide package in build jail:
SL2+    acquire shared lock to wait for package to become available
SL2-    release shared lock (no longer required, since the package will not go away ...)
        if the package could not be provided (e.g. failed to build)
            goto Abort
        -- the following lines are common with the build from port case (***)
        recursively try to provide all run dependencies
        if some run dependency could not be provided
            goto Abort
        -- ready to install
        install new version from package
        if installation fails
            goto Abort

--> Install to base from package:
SL2+    acquire shared lock to wait for package to become available
SL2-    release shared lock (no longer required, since the package will not go away ...)
        if the package could not be provided (e.g. failed to build)
            goto Abort
        -- the following lines are common with the build from port case (***)
        recursively try to provide all run dependencies
        if some run dependency could not be provided
            goto Abort
        -- create backup package and deinstall old version
        create backup package
        if the backup package cannot be created then
            goto Abort
        deinstall old version
        if deinstallation fails
            goto Abort
        -- ready to install
        install new version from package -- only this line differs from the build and install port case ...
        if installation fails
            move new package file to .NOTOK name
            re-install old version of package from saved backup file
            goto Abort
        -- cleanup after successful installation of newly built package
        delete backup package (if requested not to be kept)

--> Delayed installations:
        if ports have been selected for delayed installation:
            install missing packages -> Install from package
        remove build-only dependencies (if requested)

--> After installation from port or package:
        mark package as available (as dependency of other ports or for later installation to the base system)
(EL2-)  release exclusive lock on package name to let dependent ports proceed (if not already done in the missing run dependency case above)
        delete backup package (if it has been created and it is not to be kept)

--> Delete package:
        -- started as a background task when in jailed or repo-mode
EL2     acquire exclusively locks on this package and all run dependencies (waits until all shared locks are released for this package and the dependent packages)
        when the exclusive locks have been obtained all covered packages are deinstalled and their dependencies are added to the delete list
        -- the deinstallation is skipped, if there are no further build tasks, since then the whole jail is about to be destroyed

--> Abort:
        mark as un-buildable (with reason provided by failed function) - this will be picked up by dependent tasks when trying to use this package
SL2-    release shared locks on build dependencies (if any)
EL3-    release exclusive locks on work directories (if any)
        signal task has completed (with error)
        exit task
--]]
