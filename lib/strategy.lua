#!/usr/local/bin/lua53

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
local Action = require("portmaster.action")
local Options = require("portmaster.options")
local Exec = require("portmaster.exec")
local Param = require("portmaster.param")
local Trace = require("portmaster.trace")
local Origin = require("portmaster.origin")
local Package = require("portmaster.package")

-------------------------------------------------------------------------------------
local TRACE = Trace.trace

-------------------------------------------------------------------------------------
--
local function add_action(args)
    TRACE("ADD_ACTION_SPAWNED", args)
    Exec.spawn(Action.new, Action, args) -- XXX need to protect against simultanouos spawns for the same pkg_new !!!
end

--
local function finish_add_action()
    Exec.finish_spawned(Action.new)
end

--local REQ_FOR_TABLE = { build = {}, run = {} }

--
local function add_missing_deps(action_list) -- XXX need to also add special dependencies, somewhat similar to build dependencies
    local pkgseen = {}
    local originseen = {}
    local function collect_dep_origins(start_elem, last_elem)
        local origins = {}
        for i = start_elem, last_elem do
            local a = action_list[i]
            local o_n = a.o_n
            local depvars = o_n and o_n.depend_var
            TRACE("DEPVARS", depvars)
            if depvars then
                for n, t in pairs(depvars) do
                    TRACE("COLLECT_DEP_ORIGINS", o_n.name, n, t)
                    if t then
                        for _, dep in ipairs(t) do
                            local origin = string.match(dep, "[^:]*:([^:]*)")
                            if origin and not originseen[origin] then
                                originseen[origin] = true
                                origins[#origins + 1] = origin
                                TRACE("COLLECT_DEP_ORIGINS+", o_n.name, #origins, n, origin)
                            end
                        end
                    end
                end
            end
        end
        TRACE("COLLECT_DEP_ORIGINS!", origins)
        return origins
    end
    local function process_depends(origins)
        TRACE("PROCESS_DEPENDS", #origins)
        for _, o_n in ipairs(Origin:getmultiple(origins)) do
            local pkgname = o_n and o_n.pkgname
            if pkgname and not pkgseen[pkgname] then
                pkgseen[pkgname] = true
                local a = Action.get(pkgname)
                if not a then
                    local p_n = Package:new(pkgname)
                    p_n.origin_name = o_n.name
                    --add_action{pkg_new = p_n}
                    Action:new{pkg_new = p_n}
                end
            end
        end
        --finish_add_action()
    end
    local start_elem = 1
    local last_elem = #action_list
    while start_elem <= last_elem do
        TRACE("ADD_MISSING_DEPS:", start_elem, last_elem)
        local dep_origins = collect_dep_origins(start_elem, last_elem)
        TRACE("WAIT(NEW)START", dep_origins)
        process_depends(dep_origins)
        TRACE("WAIT(NEW)END")
        start_elem = last_elem + 1
        last_elem = #action_list
    end
end

-- return a copy of the packages cache as a table
local function all_pkgs()
    local pkgs = Package:packages_cache_load()
    local result = {}
    for _, p in pairs(pkgs) do
        result[#result+1] = p
    end
    return result
end

--
local function ports_update(filters)
    local pkgs, rest = all_pkgs(), {}
    for _, filter in ipairs(filters) do
        for _, pkg in ipairs(pkgs) do
            TRACE("PORT_UPDATE?", pkg)
            local selected, force = filter(pkg)
            TRACE("PORT_UPDATE->", pkg, selected, force)
            if selected then
                add_action{
                    is_user = true,
                    force = force,
                    pkg_old = pkg
                }
            else
                rest[#rest+1] = pkg
            end
        end
        pkgs, rest = rest, {}
    end
    finish_add_action()
end

-- add all matching ports identified by pkgnames and/or portnames with optional flavor
local function add_multiple(args)
    local pattern_table = {}
    for _, name_glob in ipairs(args) do
        local pattern = string.gsub(name_glob, "%.", "%%.")
        pattern = string.gsub(pattern, "%?", ".")
        pattern = string.gsub(pattern, "%*", ".*")
        table.insert(pattern_table, "^(" .. pattern .. ")$")
    end
    local function filter_match(pkg) -- filter return values are: match, force
        for _, v in ipairs(pattern_table) do
            if string.match(pkg.name_base, v .. "$") then
                return true, Options.force
            end
            --if pkg.origin and (string.match(pkg.origin_name, v) or string.match(pkg.origin.port, v)) then
            if string.match(pkg.origin_name, v) then
                return true, Options.force
            end
        end
    end
    --TRACE("PORTS_ADD_MULTIPLE-<", args)
    --TRACE("PORTS_ADD_MULTIPLE->", pattern_table)
    ports_update {filter_match} -- filter return values are: match, force
    for _, v in ipairs(args) do
        if string.match(v, "/") and (Param.portsdir + v + "Makefile").is_readable then
            local o = Origin:new(v)
            local p = o.pkgname
            if p then
                add_action{
                    is_user = true,
                    force = Options.force,
                    pkg_new = Package:new(p),
                    o_n = o
                }
            end
        end
    end
    finish_add_action()
    --[[
   for i, name_glob in ipairs (args) do
      local filenames = (Param.portsdir + name_glob + "Makefile").files
      if filenames then
	 for j, filename in ipairs (filenames) do
	    if access (filename, "r") then
	       local port = string.match (filename, "/([^/]+/[^/]+)/Makefile")
	       local origin = Origin:new (port)
           Action:new {
               is_user = true,
               o_n = origin
            }
	    end
	 end
      else
	 error ("No ports match " .. name_glob)
      end
   end
   --]]
end

--[[
-- process all outdated ports (may upgrade, install, change, or delete ports)
-- process all ports with old ABI or linked against outdated shared libraries
local current_libs

local function add_all_outdated()
    -- filter return values are: match, force
    local function filter_old_abi(pkg)
        return pkg.installed_abi ~= Param.abi and pkg.installed_abi ~= Param.abi_noarch, false -- true XXX
    end
    local function filter_old_shared_libs(pkg)
        local function load_current_libs()
            local t = {}
            for _, lib in ipairs(PkgDb.query {table = true, "%b"}) do
                t[lib] = true
            end
            return t
        end
        if pkg.shared_libs then
            current_libs = current_libs or load_current_libs()
            for i, lib in pairs(pkg.shared_libs) do
                --TRACE("CHECK_CURRENT_LIBS", lib, current_libs[lib])
                if not current_libs[lib] then
                    --TRACE("OLD_LIB", lib)
                    return true, true
                end
            end
        end
    end
    local function filter_is_required(pkg)
        TRACE("IS_REQUIRED?", pkg)
        return not pkg.is_automatic or pkg.num_depending > 0, false
    end
    local function filter_pass_all()
        return true, false
    end

    ports_update {
--        filter_old_abi,
        --filter_old_shared_libs, -- currently a NOP since both sets of libraries are obtained with pkg query %b
--        filter_is_required,
        filter_pass_all,
    }
end
--]]

--
local function add_all_installed()
    local installed_pkgs = all_pkgs()
    for _, pkg in ipairs(installed_pkgs) do
        TRACE("ADD_ALL_INSTALLED:", pkg.name)
        add_action{
            is_user = true,
            force = Options.force,
            pkg_old = pkg
        }
    end
    finish_add_action()
end

--
local function execute()
    -- cache local reference to ACTION_LIST
    local action_list = Action.list()
    --TRACE("ACTION_LIST", action_list)
    --Origin.dump_cache()

    -- add missing dependencies
    add_missing_deps(action_list)

    -- sort actions according to registered dependencies to check for cycles
    action_list = Action.sort_list(action_list)

    --[[ DEBUGGING ONLY!!!
    Origin.dump_cache()
    Package.dump_cache()
    Action.dump_cache()
    --]]

    -- end of scan phase, all required actions are known at this point, builds may start
    Action.perform_actions(action_list)
    Action.start_phase("finish")

    Action.report_results(action_list)
end

local function init()
    Param.phase = "scan"
    Action.block_phase("build")
    Action.block_phase("install")
    Action.block_phase("finish")
end

return {
    add_multiple = add_multiple,
    add_all_installed = add_all_installed,
    init = init,
    execute = execute,
    all_pkgs = all_pkgs,
}

--[[
Dependencies:
    user-selected port
        - build-depends:
            must be runnable at start of build process
            --> acquire(shared) RunnableLock(deps) for all build dependencies at start of build
        run-depends:
            must be runnable after installation (before stage for some ports???)
            --> acquire(shared) RunnableLock (deps) before reporting success and release of port's exclusive RunnableLock

    build dependency:
        - build-depends:
            (see above)
        - run depends:


Build goals:
    create package
        < fetch/checksum
        < provide build dependencies
        < build (in base or jail)

    install to base or jail
        from package (if pkgfile exists and not forced to rebuild)
            < verify package integrity
            < install run-dependencies
        from port
            < fetch/checksum
            < provide build dependencies
            < build (in base or jail)
            < install run-dependencies

    provide as dependency (includes special dependencies)
        in jail (for options --jailed, --repo-mode)
            from port or package --> install to jail
            < mark for deletion (after last use as dependency)
        in base
            from port or package --> install to base
            < mark for deletion (if unused and deletion of build-only tools requested)

    deinstall from base

    change port origin in package database


Build actions:
    Create package:
        < Build port

    Install or provide (to base vs. jail) from package:
        < Install all required run dependencies

    Install or provide (to base vs. jail) from port:
        < Build port
        < Install available run dependencies (avoid dead-lock)

    Build port:
        < Fetch distfiles
            < Provide build dependencies
                < Provide run dependencies
            < Provide special dependencies
                < Provide required run dependencies (depending on special depends target)

    Provide build dependency:
        < Install (to base or jail) from port or package

    Provide special dependency:
        < Fetch distfiles
        < perform build steps as indicated by special depends target

    Provide run dependency:
        < Install (to base or jail) from port or package

    Clean work directories (implicit before start of next build step or after all updates done):
        < delete no longer required work directories of port and its special dependencies

    Delete package:
        -- no dependencies

    Rename installed package:
        -- no dependencies

    Update origin in package database:
        -- no dependencies

    Update repository index:
        < Create package

Options:
    force:
        build and install from port (ignore package, no version check)
        does not recursively affect building of dependencies (another option needed for that?)
    create package:
        save ports to package repository
    create backup package:
        save installed version of a package before it is deleted
    use package:
        install from package if available
    use package for build:
        install build dependencies from package
    delete build only:
        de-install automatically installed build dependencies after last use
    keep failed work directory:
        do not delete work directory when build failed

Fundamental operations are:
    Fetch_and_checksum_test
    Provide build dependency in jail (incl. recursive run dependencies)
    Build port and provide in stage area (different make targets supported for special_depends)
    Clean work directory
    Create package for local repository from stage area
    Create backup package from base system
    Install port in jail
    Install package in jail
    Install port in base
    Install package in base
    Delete installed package from jail
    Delete installed package from base system

Concept for parallel port building:

Locks:
    1) FetchLock
    2) WorkLock
    3) PackageLock
    4) RunnableLock

Acquired locks (the table used for the locking request) should be recorded in the action to support the release operation

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
EL3+    acquire exclusive lock (on the package name that is to be generated) -- possibly with limit on number of locks
EL4+    acquire exclusive lock (on the package name that is to be generated) -- possibly with limit on number of locks
SL1+    use shared lock to wait until all distfiles are available or the fetch task has given up
SL1-    immediately release lock since distfiles are not expected to vanish once they are there
        if fetching failed for at least 1 file:
            goto Abort
        -- all distfiles have been fetched
        -- wait for build dependencies to become available (including all of their recursive run dependencies)
SL4+    use shared lock on package names of build dependencies to wait for and be able to provide build dependencies (including special dependencies, from port or package)
        -- build dependencies that have not been updated (yet) must block the provide operation!
        -- run dependencies of build dependencies are considered build dependencies, here!
        if build dependencies are marked as failed (unbuildable):
            goto Abort
        -- all build dependencies have been provided (in base or jail)
        -- all build dependencies have been (share) locked to prevent de-installation before the port has been built
EL2+    acquire exclusive lock on work directory for port and all special_depends
        -- prevent parallel builds of the same port, e.g. of different flavors
        -- pass weight for the expected number of parallel processes (half the number of cores/threads by default?)
        build port
        -- port has been built and can be packaged or installed
SL4-    release shared locks on build dependencies (only required to allow freeing of memory for locks)
        if the port build failed then
            goto Abort
        -- the port has been built and temporarily installed into the staging area
        create package (if requested)
        if the package could not b ecreated
            goto Abort
EL3-    release PackageLock now that a package has been created and could be provided (not necessarily including run dependencies of that package!)

--> Install port to the base system (from build directory) after creating a package file:
        if install conflicts are to be expected (reported based on Makefile)
            create package (unless already done)
            record for delayed installation of the package
            exit with success status
(SL3+)  try to provide all run dependencies (test for them to be available by trying to acquire shared locks on them)
        if some run dependency is missing and a package file has been created:
(EL3-)      mark the just created package as available (as dependency of other ports, to prevent dependency loops)
SL3+        use shared lock to wait for all run dependencies to become available (or failed)
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
        -- this package has been installed to the base system and all its run dependencies are available, too
EL4-    release RunnableLock to signal availability of this potential run dependency
        -- release work directory
EL2-    release locks on work directories

--> Provide package in build jail:
SL3+    acquire shared lock to wait for package to become available
SL3-    release shared lock (no longer required, since the package will not go away ...)
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
        -- the package and all its run dependencies have been installed in the jail
EL4-    release RunnableLock to signal availability of this potential run dependency

--> Install to base from package:
SL3+    acquire shared lock to wait for package to become available
SL3-    release shared lock (no longer required, since the package will not go away ...)
        if the package could not be provided (e.g. failed to build)
            goto Abort
        -- the following lines are common with the build from port case (***)
        recursively try to provide all run dependencies
        if some run dependency could not be provided (failed to build or could not be installed from a package)
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
        -- the package and all its run dependencies have been installed to the base system
EL4-    release RunnableLock to signal availability of this potential run dependency
        -- cleanup after successful installation of newly built package
        delete backup package (if requested not to be kept)

--> Delayed installations:
        if ports have been selected for delayed installation:
            install missing packages -> Install from package
        remove build-only dependencies (if requested)

--> After installation from port or package: -- already covered in the individual install flows???
        mark installed port/package as available
(EL4-)  release exclusive lock on package name to let dependent ports proceed (if not already done in the missing run dependency case above)
        delete backup package (if it has been created and it is not to be kept)

--> Delete package:
        -- started as a background task when in jailed or repo-mode
EL3     acquire exclusively locks on this package and all run dependencies (waits until all shared locks have been released for this package and the dependent packages)
        when the exclusive locks have been obtained all covered packages are deinstalled and their dependencies are added to the delete list
        -- the deinstallation is skipped, if there are no further build tasks, since then the whole jail is about to be destroyed

--> Abort:
        mark as un-buildable (with reason provided by failed function) - this will be picked up by dependent tasks when trying to use this package
SL3-    release shared locks on build dependencies (if any)
EL2-    release exclusive locks on work directories (if any)
        signal task has completed (with error)
EL3-    release PackageLock (if held - dependencies will notice the failure)
EL4-    release RunnableLock (if held - dependencies will notice the failure)
        exit task
--]]
