--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019 Stefan Eßer <se@freebsd.org>

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
-- Describe action to be performed
local function describe (action)
   local o_o = action.origin_old and action.origin_old.name
   local p_o = action.pkg_old and action.pkg_old.name
   local o_n = action.origin_new and action.origin_new.name
   local p_n = action.pkg_new and action.pkg_new.name
   local a = action.action
   TRACE ("DESCRIBE", a, o_o, o_n, p_o, p_n, pkgfile, vers_cmp)
   if a then
      if a == "delete" then
	 return string.format ("De-install %s built from %s", p_o, o_o)
      elseif a == "change" then
	 if p_o ~= p_n then
	    local prev_origin = o_o ~= o_n and " (was " .. o_o .. ")" or ""
	    return string.format ("Change package name from %s to %s for port %s%s", p_o, p_n, o_n, prev_origin)
	 else
	    return string.format ("Change origin of port %s to %s for package %s", o_o, o_n, p_n)
	 end
      elseif a == "upgrade" then
	 local from = ""
	 if p_n and action.pkg_file then
	    from = "from " .. action.pkg_file
	 else
	    from = "using " .. o_n .. (o_o ~= o_n and " (was " .. o_o .. ")" or "")
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
		  prev_pkg = p_o .. " to "
	       else
		  verb = "Replace"
		  prev_pkg = p_o .. " with "
	       end
	    end
	 end
	 return string.format ("%s %s%s %s", verb, prev_pkg, p_n, from)
      end
   end
   return ""
end

-- ----------------------------------------------------------------------------------
-- rename all matching package files (excluding package backups)
local function pkgfiles_rename (action)
   local pkgname_old = action.pkg_old.name
   local pkgname_new = action.pkg_new.name
   for i, pkgfile_old in glob (PACKAGES .. "*/" .. pkgname_old .. ".t??", GLOB_ERR) do
      if access (pkgfile_old, "r") and not strpfx (pkgfile_old, PACKAGES_BACKUP) then
	 local pkgfile_new = dirname (pkgfile_old) .. "/" .. pkgname_new .. pkgfile_old:gsub (".*(%.%w+)", "%1")
	 return run ("/bin/mv", {as_root = true, to_tty = true, pkgfile_old, pkgfile_new})
      end
   end
end

-- ----------------------------------------------------------------------------------
-- convert origin with flavor to sub-directory name to be used for port options
-- move the options file if the origin of a port is changed
local function portdb_update_origin (action)
   local portdb_dir_old = action.origin_old:portdb_path ()
   if is_dir (portdb_dir_old) and access (portdb_dir_old .. "/options") then
      local portdb_dir_new = action.origin_new:portdb_path ()
      if not is_dir (portdb_dir_new) then
	 return run ("/bin/mv", {as_root = true, to_tty = true, portdb_dir_old, portdb_dir_new})
      end
   end
end

-- check for build conflicts immediately before a port build is started
local function check_build_conflicts (action)
   local origin = action.origin_new.name
   local result = {}
   local pattern_list = origin:port_var {table = true, "BUILD_CONFLICTS"} -- or ??? $(origin_var "$origin_new" CONFLICTS)
   for i, pattern in ipairs (pattern_list) do
      for j, pkgname in ipairs (PkgDb.query {table = true, glob = true, "%n-%v", pattern}) do
	 table.insert (result, pkgname)
      end
   end
   return result
end

-- create package file from staging area of previously built port
local function package_create (origin)
   local origin_new = action.origin_new.name
   local pkgname = action.pkg_new.name
   local pkgfile = Package:filename (PACKAGES .. "All", pkgname, Options.package_format)
   if Options.skip_recreate_pkg and access (pkgfile, "r") then
      Msg.cont (0, "A package file for", pkgname, "does already exist and will not be overwritten")
   else
      Msg.cont (0, "Create a package for new version", pkgname)
      if Options.jailed then
	 if not origin:port_make {to_tty = true, "-D", "_OPTIONS_OK", "PACKAGES=/tmp", "PKG_SUFX=." .. PACKAGE_FORMAT, "package"} then
	    return false
	 end -- >&4
	 local filename = package_filename (PACKAGES, "All", pkgname, Options.package_format)
	 os.rename (JAILBASE .. "/tmp/All/" .. filename, PACKAGES .. filename) -- <se> SUDO required ???
      else
	 if not origin:port_make {to_tty = true, "-D", "_OPTIONS_OK", "PKG_SUFX=." .. Options.package_format, "package"} then
	    return false
	 end -- >&4
      end
      assert (Options.dry_run or access (pkgfile, "r"), "Package file has not been created")
      Package.category_links_create (pkgfile)
      Msg.cont (0, "Package saved to", pkgfile)
   end
   return true
end

-- clean work directory and special build depends (might also be delayed to just before program exit)
local function port_clean (action)
   local origin_new, special_depends = action.origin_new, action.special_depends or {}
   table.insert (special_depends, origin_new.name)
   for i, origin_target in ipairs (special_depends) do
      local target = target_part (origin_target)
      local origin = Origin:new (origin_target:gsub (":.*", ""))
      if target ~= "fetch" and target ~= "checksum" then
	 return origin:port_make {to_tty = true, jailed = true, "-D", "NO_CLEAN_DEPENDS", "clean"}
      end
   end
end

-- ----------------------------------------------------------------------------------
-- add special build dependency on e.g. checked out sources of another port
local function special_builddep_add (origin_new, dep_origin_target)
   error ("NYI")
   if not SPECIAL_DEPENDS[origin_new.name] then
      SPECIAL_DEPENDS[origin_new.name] = {}
   end
   table.insert (SPECIAL_DEPENDS[origin_new.name], dep_origin_target)
   local dep_origin = dep_origin_target:match (":.*", "")
   Distfile.fetch (dep_origin)
   Msg.cont (1, "Building port", origin_new.name, "depends on 'make", target_part (dep_origin_target), "of port", dep_origin.name)
end

-- ----------------------------------------------------------------------------
-- register build dependencies for given origin
-- 
-- Build-Deps:
-- 
-- For jailed builds or if delete-build-only is set:
-- ==> Register for each dependency (key) which port (value) relies on it
-- ==> The build dependency (key) can be deleted, if it is *not also a run dependency* and after the dependent port (value) registered last has been built
-- 
-- Run-Deps:
-- 
-- For jailed builds only (???):
-- ==> Register for each dependency (key) which port (value) relies on it
-- ==> The run dependency (key) can be deinstalled, if the registered port (value) registered last has been deinstalled

local RECURSIVE_MSG = ""

-- print first line for new port being checked for the need of upgrades or changes
local function print_checking (action)
   local origin = action.origin_new or action.origin_old
   Msg.title_set ("Check " .. origin.name)
   Msg.cont (1, "Check", origin.name .. RECURSIVE_MSG)
end

local function register_depends (action, origin, build_type, dep_type, target)
   TRACE ("REGISTER_DEPENDS", build_type, dep_type, origin.name)
   local RECURSIVE_MSG = " (to " .. dep_type .. " " .. origin.name .. RECURSIVE_MSG .. ")"
   local sub_build_type = build_type == "provide" and "provide" or "auto"
   -- fetch list of origin instances this port depends on
   local depends_list = origin:depends (dep_type)
   for i, dep_origin in ipairs (depends_list) do
      TRACE ("DEP_ORIGIN:", dep_origin)
      -- check whether the port is flavored and use the default flavor if none is specified
      if not dep_origin:flavor () then
	 dep_origin:set_default_flavor ()
      end
      -- check for special make target of dependency
      if dep_type == "build" then
	 local make_target = target_part ( tostring (dep_origin))
	 if make_target ~= "install" then
	    if not SPECIAL_DEPS[origin.name] then
	       SPECIAL_DEPS[origin.name] = {}
	    end
	    table.insert (SPECIAL_DEPS[origin.name], dep_origin)
	    if make_target == "build" or make_target == "stage" then
	       -- this port will only be built but not installed (e.g. to provide library for static linking)
	       register_depends (action, dep_origin, "auto", "build")
	    end
	 end
      end
      --
      if not Action:new {build_type = sub_build_type, dep_type = dep_type, origin_new = dep_origin} then
	 return false -- or fail "Cannot add $dep_type dependency on $dep_origin for $origin" ???
      end
      -- local depends_list2 = {}
      -- if UPGRADES[dep_origin] then depends_list2:insert (dep_origin) end
      -- for i, dep_origin in ipairs (depend_list2) do
      if Options.jailed or Options.delete_build_only then
	 Msg.cont (2, "Register dependency:", origin, "needs", dep_origin.name, "(" .. build_type .. "/" .. dep_type .. ")")
	 BUILD_DEPS[dep_origin.name] = origin.name
      end
      -- end
   end
   return true
end

-- update port origin in installed package
local function register_moved (action)
   action.action = "move"
   if not Options.fetch_only then
      Progress.num_incr ("moves")
      Progress.show_task (Action:describe ())
   end
   return true
end

-- rename package without version change
local function register_pkgname_chg (action)
   local origin_new, pkgname_old, pkgname_new = action.origin_new, action.pkgname_old, action.pkgname_new
   action.action = "pkgname_chg"
   if not Options.fetch_only then
      if action.origin_new:excluded () then
	 return false
      end
      Progress.num_incr ("renames")
      Progress.show_task (Action:describe ())
   end
   return true
end

-- record build type for action planning after all dependencies are known
local function record_dep_type (action, build_type, dep_type)
   TRACE ("record_dep_type", action.origin_new, build_type, dep_type)
   if not Options.jailed or build_type == "provide" then
      if dep_type == "build" then
	 BUILDDEP[action.name] = true
      elseif dep_type == "run" then
	 RUNDEP[action.name] = true
      else
	 error ("Illegal dep_type " .. dep_type .. " in record_dep_type for " .. action.origin_new.name) -- TEMPORARY
      end
   end
end

-- return filename if a package file with correct ABI exists and a package may be used
local function check_use_package (action)
   if not action.pkg.pkgfile then
      local build_type, dep_type, pkgname = action.build_type, action.dep_type, action.pkg.name
      if pkgname and pkgname ~= "" then
	 if build_type ~= "force" and not Options.packages and (not Options.packages_build or dep_type ~= "build") then
	    action.pkg.pkgfile = Package.file_search (pkgname)
	 end
      end
   end
end

-- install or upgrade named port from required parameter $origin_new
--
-- use cases:
-- - origin_old == "": install new port
-- - origin_old == origin_new: upgrade port
-- - origin_old != origin_new: upgrade port from changed origin
--
-- in case of an upgrade, pkgname_old will be replaced by the newly built port pkgname_new
local function register_upgrade (action)
   TRACE ("register_upgrade", action.build_type, action.dep_type, action.origin_old.name, action.origin_new.name, action.pkgname_old, action.pkgname_new, action.pkgfile)
   if action.action then
      return true
   end
   action.action = "upgrade" -- ??? make more specific !!! (install, build, provide, ...)
   local cause
   --origin_new:record_dep_type (build_type, dep_type)
   -- register new package name and (old origin and package name, if applicable and changed)
   if Options.repo_mode then
      action.origin_old = nil
      action.pkg_old = nil
   end
   assert (not action.origin_old or action.pkg_old, "no package name for port " .. action.origin_old.name)
   --
   if not Options.fetch_only then
      action.pkgfile = action.pkgfile or action:check_use_package ()
   end
   --
   if action.pkgfile then
      if not Options.jailed or action.build_type == "provide" then
	 Progress.show_task (Action:describe ())
      end
      -- installing a package or a package dependency requires pre-installation of run dependencies
      assert (register_depends (action, origin_new, build_type, "run"), "A required run dependency could not be provided")
   else
      Progress.show_task (action:describe ())
      -- make config if building from a port
      if not action.origin_new:check_options () then
	 return false
      end
      -- add build dependencies (and stop if a dependency is missing???)
      if Options.jailed then
	 assert (register_depends (action, action.origin_new, "provide", "build"), "A required build dependency could not be added")
      else
	 assert (register_depends (action, action.origin_new, build_type, "build"), "A required build dependency could not be added")
      end
   end
   -- fetch and check distfiles in background if a port will be built
   if not action.pkgfile and not Options.dry_run then
      Distfile.fetch (action.origin_new.name)
   end
   -- add to WORKLIST behind (!) the (recursively added) build dependencies
   Worklist.add (action.origin_new)
   if Options.jailed and action.build_type ~= "provide" and not Options.repo_mode then
      Worklist.add_delayedlist (action.origin_new)
   end
   if action.build_type ~= "provide" and not action.pkgfile then
      register_depends (action, action.origin_new, "auto", "run")
   end
end

-- delete installed package
local function register_delete (action)
   action.action = "delete"
   if not Options.fetch_only then
      Progress.show_task (Action:describe ())
      Progress.num_incr ("deletes")
   end
   return true
end

-- check conflicts of new port with installed packages (empty table if no conflicts found)
local function conflicts (action)
   local list = {}
   conflicts = action:port_make {table = true, safe = true, "check-conflicts"}
   if conflicts then
      for i, line in ipairs (conflicts) do
	 local pkgname = line:match ("^%s+(%S+)%s*")
	 if pkgname then
	    table.insert (list, Package:new (pkgname))
	 elseif #list > 0 then
	    break
	 end
      end
   end
   return list
end

-- ----------------------------------------------------------------------------------
-- return true and list of conflicts, if conflicting installed package shall be kept
-- return false and list of conflicts, if conflicting installed package shall be replaced
local function check_conflicts_override (action, build_type)

   local PRIO = {
      auto = 1,
      build = 1,
      provide = 1,
      run = 1,
      checkabi = 1,
      user = 2,
      force = 3,
   }
   
   -- check for conflicts with already installed packages
   -- strategy: 1) choose forced over user installed over automatic package
   --           2) choose already installed package over new package
   -- <se> ToDo: support multiple conflicting packages
   local conflicting_pkg
   if build_type ~= "unused" then
      conflicting_pkg = conflicts (action)

      for i, pkg in ipairs (conflicting_pkg) do
	 print ("CONFL-PKG:", pkg) -- TABLE !!! ???
	 local prio_new = PRIO[build_type]
	 assert (prio_new, "check_conflicts_override: Unknown build_type " .. build_type)
	 -- if this conflicting port was specifically requested by the user or it is in conflict with
	 --  an automatic package then replace the conflicting package with the requested one
	 if PkgDb.automatic_check (pkg) then
	    prio_old=1
	 else
	    prio_old=2
	 end
	 -- replace automatically installed package by new dependency if prio of new package is higher than old one
	 if prio_new > prio_old then
	    return false, conflicting_pkg
	 end 
	 --  replace automatically installed package by new dependency if prio same but old only referenced by just this port
	 if prio_new == prio_old and PkgDb.query {"%#r", pkg} <= 1 then
	    return false, conflicting_pkg
	 end -- <= or < ???
	 -- ignore dependency and use installed package instead
	 return true, conflicting_pkg
      end
   end
   -- no conflicts found
   return true, nil
end

-- check whether this origin has already been registered and register dep_type in that case
local function check_seen (action, build_type, dep_type)
   record_dep_type (action, build_type, dep_type)
   if build_type == "provide" and not UPGRADES[action.name] then
      return false
   end
   return SEEN[action.name]
end

-- try to find old origin for given new origin (typically a dependency)
-- return result in variable origin_old in external scope!
local function guess_origin_old (action)
   local o_o, o_n, p_o, p_n = action.origin_old, action.origin_new, action.pkg_old, action.pkg_new
   -- <se> Add faster test for the common case of origin_old = origin_new !!!
   -- the pkg query takes too long to perform for each port
   -- check whether the package name with matching major version number can be found in the package registry
   if not o_o then
      if not p_o then
	 p_o = PkgDb.nearest_pkgname (p_n)
	 if p_o then
	    o_o =  PkgDb.origin_from_pkgname (p_o)
	 end
      end
      -- try to find the old origin if the port has been moved to a new origin
      -- <se> MULTIPLE ???
      if not o_o and o_n then
	 o_o = origin_old_from_moved_to_origin (o_n)
      end
      if not o_o and p_n then
	 -- try whether the new package name sans version can be found in the package registry
	 o_o = PkgDb.origin_from_pkgname (p_n:strip_version ())
	 if not o_o then
	    -- check whether a port with the new origin has already been registered in the package registry
	    if PkgDb.pkgname_from_origin (o_n) then
	       o_o = o_n
	    end
	 end
      end
      action.origin_old = o_o
   end
end

-- if an upgrade will be required then check for conflicts 
local function conflicts_adjust (action)
   if action.origin_new and action.pkg_old ~= action.pkg_new then
      -- get name of conflicting package, conflict_type==0 means the installed package shall be kept
      conflict_type, conflicting_pkg = check_conflicts_override (action.origin_new, action.build_type)
      if conflicting_pkg and conflicting_pkg[1] then
	 action.pkg_old = conflicting_pkg[1] -- ERROR this is a list, use first element for now ???
	 action.origin_old = PkgDb.origin_from_pkgname (action.pkg_old)
	 if conflict_type then
	    -- keep conflicting package that appears to be preferred by the user
	    Msg.cont (1, "The dependency for", action.origin_new.name, "seems to be handled by", conflicting_pkg, "built from", action.origin_old.name) -- origin_old or origin_new ???
	    TRACE ("ON1", action.origin_new.name)
	    action.origin_new = origin_new_from_old (action.origin_old, action.pkg_old)
	    TRACE ("ON2", action.origin_new.name)
	    action.pkg_new = action.origin_new:port_var {jailed = true, trace = true, "PKGNAME"}
	    if not action.pkg_new then
	       action.origin_new = nil
	       TRACE ("ON3", "<nil>")
	    end
	 else
	    -- replace automatically installed package by new dependency
	    Msg.cont (0, conflicting_pkg, " will be deinstalled")
	    Msg.cont (0, action.origin_new.name, " will replace this conflicting package installed from ", origin_old.name)
	    -- <se> check build_type if delete-build-only is set - set_add BUILD_ONLY / set_rm BUILD_ONLY $origin_new ???
	    --#[ -n "$Options.delete_build_only" ] && record_dep_type "$build_type, dep_type, origin_old"
	    -- prevent further update checks for origin_old
	    action.origin_old:mark_seen () -- <se> this prevents later demand building of this port!?!
	    -- remove conflicting port from worklist, if it has already been added
	    Worklist.remove (action.origin_old)
	    -- sleep in case there will be a config screen for the new package
	    if not Options.dry_run then
	       sleep (4)
	    end
	 end
      end
   end
   return true -- return false in case of unresolvable conflict ???
end

   local function derive_pkgname_old_from_origin_old (action)
      local p_o, o_o = rawget (action, pkg_old), rawget (action, origin_old)
      if not p_o and o_o then
	 action.pkg_old = o_o.pkg_old
      end
   end

   local function derive_pkgname_new_from_origin_new (action)
      local p_n, o_n = rawget (action, pkg_new), rawget (action, origin_new)
      if not p_n and o_n then
	 action.pkg_new = o_n.pkg_new
      end
   end

   local function derive_pkgname_new_from_origin_new_jailed (action)
      local p_n, o_n = rawget (action, pkg_new), rawget (action, origin_new)
      if not p_n and o_n then
	 action.pkg_new = o_n.pkg_new -- WHY JAILED ???
      end
      assert (action.pkg_new, "No valid port directory exists for " .. o_n.name)
   end

   local function verify_pkgname_old_matches_new (action)
      local p_o, p_n = rawget (action, pkg_old), rawget (action, pkg_new)
      if p_o and p_n then
	 --[[
	 if p_o.name_base_major ~= p_n.name_base_major then -- too strict without further tests!
	    action.pkg_new = nil -- assume package mismatch if names and major numbers do not agree
	 end
	 --]]
	 if p_o.name_base ~= p_n.name_base then -- too strict without further tests!
	    action.pkg_new = nil -- assume package mismatch if names and major numbers do not agree
	 end
      end
   end

   local function derive_pkgname_new_from_origin_old (action)
      local p_n, o_o = rawget (action, pkg_new), rawget (action, origin_old)
      if not p_n and o_o then
	 action.pkg_new = o_o.pkg_new -- || return 1 # <se> EXPERIMENTAL to prevent deinstallation on Makefile inconsistency!!! --> destroys -o option!!!
	 verify_pkgname_old_matches_new (action)
      end
   end

   local function guess_origin_old_from_origin_pkgname_new (action)
      local p_n, o_o, o_n = rawget (action, pkg_new), rawget (action, origin_old), rawget (action, origin_new)
      if not o_o and o_n and p_n then
	 action.origin_old = guess_origin_old (o_n, p_n)
      end
   end

   local function derive_origin_new_from_origin_and_pkgname_old (action)
      local p_o, o_o, o_n = rawget (action, pkg_old), rawget (action, origin_old), rawget (action, origin_new)
      if not o_n and p_o then
	 o_n = origin_new_from_old (o_o, p_o)
	 if o_n and not o_n:check_path () then
	    TRACE ("NIL")
	    o_n = nil
	 end
	 action.origin_new = o_n
      end
   end

   local function derive_pkgname_old_from_origin_new (action)
      local p_o, o_o, o_n = rawget (action, pkg_old), rawget (action, origin_old), rawget (action, origin_new)
      if not p_o and o_n and o_o ~= o_n then
	 p_o = o_n:curr_pkg () -- PkgDb.pkgname_from_origin (o_n)
	 if not p_o then
	    -- the new origin does not match any installed package, check MOVED
	    o_o = origin_old_from_moved_to_origin (o_n)
	    if o_o then
	       p_o = o_o:curr_pkg () -- PkgDb.pkgname_from_origin (o_o)
	       if not p_o then
		  return
	       end
	    end
	 end
	 action.pkg_old = p_o
      end
   end

   local function guess_pkgname_old_from_pkgname_new (action)
      local p_o, p_n = rawget (action, pkg_old), rawget (action, pkg_new)
      if not p_o and p_n then
	 local result = PkgDb.query {"%n-%v", p_n:name_base ()}
	 if result then
	    action.pkg_old = Package:new (result[1])
	 end
      end
   end

-- assess what to do for given old and new origin and old package name
--
-- supported parameter combinations:
-- - origin_old, pkgname_old for "portmaster -a"
-- - origin_old, origin_new for portmaster -o"
-- - origin_new for dependencies
--
-- strategy:
-- - assert that at least origin_new or pkgname_old are provided
-- - if no pkgname_old given: try to lookup pkgname_old in pkgdb by given origin_old or origin_new
-- - abort if pkgname_old is locked or excluded (with error code returned???)
-- - on empty origin_new ==> delete pkgname_old ==> return
-- - get pkgname_new from port at origin_new
-- - check excludes for pkgname_new (and return with error code if it may not be installed)
-- - determine whether the port version is unchanged ==> just update the package registry ==> return
-- - register port for actual build process
--
-- use cases:
-- - valid origin_old and pkgname_old (for "-a" or a pkgname argument) (?should passing only origin_old also be supported?)
--   --> if origin_new also passed as argument (i.e., user enforced change of origin): use origin_new as passed in
--	else check for moved origin (in /usr/ports/MOVED) and set origin_new for moved ports
--	check for conflict of port built from origin_old with installed ports and try to resolve the conflict
--	origin_new := origin_old if not moved and no conflicts and port still exists
--	more cases to consider?
--
-- - valid origin_new from dependency or as direct parameter (and no other package names or origins)
--   --> if origin_new in pkgdb and pkgnames match then origin_old := origin_new
--	else check for moved origin (in /usr/ports/MOVED) (reverse lookup new --> old) and validate origin in pkgdb
--	search in pkgdb an origin that corresponds to pkgname_new determined from origin_new
--	more cases to consider?
--
-- if the new port conflicts with an installed one, a heuristic attempts to guess
-- whether the conflicting port is a valid substitute, whether it is to be replaced
-- by the new port, or whether the upgrade attempt will fail (???)
--
-- build_type is one of "force" "user" "auto" "provide" "unused"
-- dep_type is one of "build" "run" (used for "make list-${dep_type}-depends")
local function collect_action_params (action)
   local function derive_origin_old_from_pkgname_old (action)
      local p_o, o_o = action.pkg_old, action.origin_old
      if not o_o and p_o then
	 action.origin_old = p_o:origin_old ()
      end
   end

   local TRACE = print
   -- expect to be called with at least either an old package name or a new port origin
   action.origin_old = action.origin_old or action.pkg_old and action.pkg_old.origin

   TRACE ("ACTION:NEW", action.build_type, action.dep_type, action.origin_old, action.pkg_old)
   assert (action.origin_new or action.pkg_old,
	   "choose_action called with " .. tostring (action.origin_old) .. ", " .. tostring (action.origin_new) .. ", " .. tostring (action.pkg_old) .. " (need origin_new or pkgnamee_old)")
   assert (action.build_type, "invalid build_type " .. tostring (action.build_type) .. " .. for action on " .. tostring (action.origin_old) or tostring (action.origin_new))
   assert (action.dep_type, "invalid dep_type " .. tostring (action.dep_type) .. " .. for action on " .. tostring (action.origin_old) or tostring (action.origin_new))
   -- if this package is to be "provided" then it is a run dependency of a build dependency and should be treated as another build dependency
   if action.build_type == "provide" then
      action.dep_type = "build"
   end
   -- 
   Msg.start (0, "")
   --
   derive_origin_old_from_pkgname_old (action) -- if an old package name has been given then we can find the old origin
   derive_pkgname_new_from_origin_new (action) -- if a currently valid origin has been passed in the new package name is determined too
   -- 
   derive_pkgname_old_from_origin_old (action) -- try to find new package name from old or new origin via the port
   derive_pkgname_new_from_origin_old (action) -- 
   -- if a new origin has been provided (either as dependency or via the -o option) lookup new package name and try to determine old origin and package name, unless already known
   if action.origin_new then
      if check_seen (action.origin_new, action.build_type, action.dep_type) then
	 return true
      end
      print_checking (action)
   end
   derive_pkgname_new_from_origin_new_jailed (action) -- 
   guess_origin_old_from_origin_pkgname_new (action) --
   derive_pkgname_old_from_origin_old (action) --
   -- 
   print_checking (action)
   derive_origin_new_from_origin_and_pkgname_old (action) -- 
   derive_pkgname_new_from_origin_new_jailed (action)
   -- 
   assert (action.origin_new or action.origin_new, "choose_action needs at least the old or new origin")
   -- check for conflicts and adjust origins and packages if required
   if not conflicts_adjust (action) then
      return false
   end
   -- short-cut if the new package is already available as a package file
   if Options.jailed and action.build_type ~= "force" or action.build_type == "checkabi" then
      action.pkgfile = action:check_use_package ()
      if action.pkgfile and (Options.repo or action.build_type == checkabi) then
	 return true
      end
   end
   -- try to obtain old package name from old or new origin or new package name # <se> probably not required ???
   derive_pkgname_old_from_origin_old (action)
   -- <se> MOVED ORIGIN HANDLING MUST BE PERFORMED BY CALLERS OF pkgname_old_from_origin_new() !!!
   derive_pkgname_old_from_origin_new (action)
   -- 
   guess_pkgname_old_from_pkgname_new (action)
   --
   if action.pkg_old then
      --# set_contains PKGSEEN "$pkgname_old" && return 0
      --# set_add PKGSEEN "$pkgname_old"
      -- check for locked or excluded ports
      if check_locked (action.pkg_old.name) then
	 return true -- true or false ???
      end
      if action.pkg_old:check_excluded () then
	 return true -- true or false ???
      end
   end
end

local function strategy (action)
   -- option -t/--thorough has been passed and the port is unused
   if build_type == "unused" then
      TRACE ("register_delete", action.pkg_old)
      register_delete (action)
      local count = PkgDb.query {"%#r", action.pkg_old}
      if count > 0 then
	 Msg.cont (1, "It was only required for", count, "now stale ports:")
	 Msg.cont (1, PkgDb.query {'%rn-%rv', action.pkg_old})
      end
      return true
   end
   -- port has been deleted
   if not action.pkg_new then
      assert (not action.origin_new, "no pkgname_new for origin_new " .. action.origin_new.name)
      -- delete package if no new package name has been found
      TRACE ("register_delete", action.pkg_old)
      register_delete (action)
      return true
   end
   --
   if action.origin_new:check_excluded () then
      return true
   end
   if action.pkg_new:check_excluded () then
      return true
   end
   --
   local version_old
   if action.pkg_old then
      version_old = Package.version (action.pkg_old)
   end
   local version_new = Package.version (action.pkg_new)
<   TRACE ("CHOOSE_ACTION", "-->", action.build_type, action.dep_type, action.origin_old, action.origin_new, action.pkg_old, action.pkg_new, action.pkgfile)
   if action.build_type == "force" or
      action.build_type == "provide" or
      action.build_type == "checkabi" or
      --#	[ -n "$Options.jailed" -a "$build_type" = "provide" ] ||
      --#	[ -n "$Options.jailed" -a "$dep_type" = "build" ] ||
      version_old ~= version_new and not action.pkgfile or
   action.origin_old and action.origin_new and action.origin_old:flavor () ~= action.origin_new:flavor () then
      -- perform upgrade if version change or forced
      register_upgrade (action)
   else
      -- no actual upgrade required, just changes to the package registry ...
      if action.origin_old and action.origin_old ~= action.origin_new then
	 TRACE ("register_moved", action.origin_old, action.origin_new, action.pkg_old)
	 if not register_moved (action) then
	    return false
	 end
      end
      if action.pkg_old and action.pkg_old ~= action.pkg_new then
	 TRACE ("register_pkgname_chg", action.origin_new, action.pkg_old, action.pkg_new)
	 if not register_pkgname_chg (action) then
	    return false
	 end
      end
   end
   Progress.show_task (action:describe ())
   mark_seen (action.origin_new)
   if Options.thorough then
      register_depends (action, action.origin_new, "auto", "build") -- CHECK VALUE OF ACTION
      register_depends (action, action.origin_new, "auto", "run")
   end
   return true
end

--
local function register_delayed_installs ()
   if Options.delay_installation then
      for i, origin in ipairs (WORKLIST) do
	 print ("DELAYED-INSTALL:", i, origin)
	 if BASEDEP[origin] then
	    Worklist.add_delayedlist (origin)
	    print ("Delayed:", origin)
	 end
      end
   end
end

-- 
local function register_delete_build_only (action)
-- 	local origin build_deps has_build_deps has_run_deps dep_origin package dep_package
   Msg.start (2, "")
   local has_run_deps = false
   local has_build_deps = false
   for i, origin in ipairs (table_keys (BUILD_DEPS)) do
--# package = PKGNAME_NEW "$origin")
--#[ -z "$package" ] && fail_bug "No package name for $origin"
--#[ -z "$package" ] && continue
      local dep_origin = BUILD_DEPS[origin]
      if RUNDEP [origin] then
--#dep_package="$(dict_get PKGNAME_NEW "$dep_origin")"
--#[ -z "$dep_package" ] && fail_bug "No package name for $dep_origin"
	 --#[ -z "$dep_package" ] && continue
	 if not DEP_DEL_AFTER_RUN[dep_origin] then
	    DEP_DEL_AFTER_RUN[dep_origin] = {}
	 end
	 table.insert (DEP_DEL_AFTER_RUN[dep_origin], origin)
	 Msg.cont (2, "Last run dependency of", origin, "is", dep_origin)
	 has_run_deps = true
      else
	 if not DEP_DEL_AFTER_BUILD[dep_origin] then
	    DEP_DEL_AFTER_BUILD[dep_origin] = {}
	 end
	 table.insert (DEP_DEL_AFTER_BUILD[dep_origin], origin)
	 Msg.cont (2, "Last build dependency of", origin, "is", dep_origin)
	 has_build_deps = true
      end
   end
   if has_build_deps then
      Msg.start (2, "Delete build deps after build has completed:")
      for i, origin in ipairs (table_keys (DEP_DEL_AFTER_BUILD)) do
	 Msg.cont (2, origin, "built ==> deinstall", table.concat(DEP_DEL_AFTER_BUILD[origin], ", "))
      end
   end
   if has_run_deps then
      Msg.start (2, "Delete run deps after package has been deinstalled:")
      for i, package in ipairs (table_keys (DEP_DEL_AFTER_RUN)) do -- ??? package vs. origin
	 Msg.cont (2, package, "deleted ==> deinstall", table.concat(DEP_DEL_AFTER_RUN[package]))
      end
   end
end

-- return old origin@flavor for given new origin@flavor
local function origin_old_from_moved_to_origin (origin_new)
--# [ -n "$OPT_jailed" ] && return 1 # assume PHASE=build: the jail is empty, then
   local moved_file = PORTSDIR .. "MOVED"
   local lastline = ""
   for line in shell_pipe (GREP_CMD, "'^[^|]+|" .. origin_new.name .. "|'", moved_file) do
      lastline = line
   end
   if lastline then
      local origin_old = string.match (lastline, "^([^|]+)|")
      return Origin:new (origin_old)
   end
end

--#pkgdb_pkgname_from_origin_jailed () {
--#	local origin="$1"
--#	local dir=$(dir_part "$origin")
--#	local flavor=$(flavor_part "$origin")
--#	local pkgname tag value result
--#
--#	[ -z "$dir" ] && return 1
--#
--##	if [ -n "$flavor" ]; then
--##		# <se> PKGNAME_OLD is only pre-loaded if CACHED_FLAVORS is set
--##		dict_get PKGNAME_OLD "$origin" && return 0
--##	fi
--#	for pkgname in $(PkgDb.query_jailed "%n-%v" "$dir"); do
--#		if pkgdb_flavor_check "$pkgname" "$flavor"; then
--#			echo "$pkgname"
--#			return 0
--#		fi
--#	done
--#	return 1
--#}

-- install newly built port
local function install (action)
   return action.origin:port_make {to_tty = true, jailed = true, as_root = true, "install"}
end

-- de-install (possibly partially installed) port after installation failure
local function deinstall_failed (action)
   Msg.cont (0, "Installation of", action.pkg_new, "failed, deleting partially installed package")
   return action.origin_new:port_make {to_tty = true, jailed = true, as_root = true, "deinstall"}
end

-- install or upgrade a port
local function perform_install_or_upgrade (action)
   local skip_install, pkgfile, seconds
   local origin_old = action.origin_new.origin
   local pkgname_old = action.origin_new.pkgname_old
   local pkgname_new = action.origin_new.pkgname_new
   local pkgfile = action.pkgfile
   --
   local taskmsg
   if Options.fetch_only then
      taskmsg = "Fetching all distfiles for $origin_new"
   else
      -- has a package been identified to be used instead of building the port?
      pkgfile = USEPACKAGE[origin_new]
      taskmsg = describe_task (origin_old, origin_new, pkgname_old, pkgname_new, pkgfile)
      if (Options.skip_install or Options.jailed) and BUILDDEP[origin_new] then
	 skip_install = true
      end
   end
   progress_show_task (taskmsg)
   -- if not installing from a package file ...
   if not pkgfile then
      assert (origin_new:wait_checksum ())
      if not Options.fetch_only then
	 if not Options.dry_run then
	    seconds = os.time()
	    if not perform_portbuild (origin_new, pkgname_new) then
	       return false
	    end
	 end
      end
   end
   -- install build depends immediately but optionally delay installation of other ports
   if not skip_install then
      if not perform_installation (action) then
	 return false
      end
      if not Options.jailed then
	 worklist_remove (origin_new)
      end
   end
   -- perform some book-keeping and clean-up if a port has been built
   if not pkgfile then
      -- preserve file names and hashes of distfiles from new port
      distinfo_cache_update (origin_new, pkgname_new)
      -- backup clean port directory and special build depends (might also be delayed to just before program exit)
      if not Options.no_post_clean then
	 port_clean (origin_new, special_depends)
	 -- delete old distfiles
	 distfiles_delete_old (origin_new, pkgname_old) -- OUTPUT
	 if seconds then
	    seconds = os.time () - seconds
	 end
      end
   end
   -- report success
   if not Options.dry_run then
      message_success_add (taskmsg, seconds)
   end
   return true
end

-- delete build dependencies after dependent ports have been built
local function perform_post_build_deletes (origin)
   local origins = DEP_DEL_AFTER_BUILD[origin.name]
   DEP_DEL_AFTER_BUILD[origin.name] = nil
   local del_done = false
   while origins do
      for i, origin in pairs (origins) do
	 if package_deinstall_unused (origin) then
	    del_done = true
	 end
      end
      origins = del_done and table_keys (DELAYED_DELETES)
   end
end

-- deinstall package files after optionally creating a backup package
local function perform_deinstall (action)
   assert (Package.deinstall (action.pkg.name, Options.backup), "Cannot delete package " .. action.pkgname)
end

-- ----------------------------------------------------------------------------------
-- perform all steps required to build a port (extract, patch, build, stage, opt. package)
local function perform_portbuild (action)
   local origin_new = action.origin_new
   local automatic
   local pkgname_new = action.pkg.name
   local special_depends = action.special_depends
   TRACE ("perform_portbuild", origin_new.name, pkgname_new, table.unpack (special_depends or {}))
   if not Options.no_pre_clean then
      port_clean (action)
   end
   -- check for special license and ask user to accept it (may require make extract/patch)
   -- may depend on OPTIONS set by make configure
   if not DISABLE_LICENSES then
      if not origin_new:check_license () then
	 return false
      end
   end
   -- <se> VERIFY THAT ALL DEPENDENCIES ARE AVAILABLE AT THIS POINT!!!
   -- extract and patch the port and all special build dependencies ($make_target=extract/patch)
   if special_depends and not port_provide_special_depends (special_depends) then
      return false
   end
   if not origin_new:port_make {to_tty = true, jailed = true, "-D", "NO_DEPENDS", "-D", "DEFER_CONFLICTS_CHECK", "-D", "DISABLE_CONFLICTS", "FETCH_CMD=true", "patch"} then
      return false
   end
   -- check whether build of new port is in conflict with currently installed version
   local deleted = {}
   local conflicts = check_build_conflicts (origin_new)
   for i, pkg in ipairs (conflicts) do
      if pkg == pkgname_old then
	 -- ??? pkgname_old is NOT DEFINED
	 Msg.cont (0, "Build of", origin_new.name, "conflicts with installed package", pkg .. ", deleting old package")
	 automatic = PkgDb.automatic_get (pkg)
	 table.insert (deleted, pkg)
	 perform_pkg_deinstall (pkg)
	 break
      end
   end
   -- build and stage port
   progress_show ("Build", pkgname_new)
   if origin_new:port_make {to_tty = true, jailed = true, "-D", "NO_DEPENDS", "-D", "DISABLE_CONFLICTS", "-D", "_OPTIONS_OK", "build", "stage"} then
      -- create package file from staging area
      if Options.create_package then
	 if not package_create (origin_new) then
	    Msg.cont (0, "Could not write package file for", pkgname_new)
	    return false
	 end
      end
   else
      if deleted[1] then
	 package_recover (deleted, automatic)
	 return false
      end
   end
   return true
end

-- perform actual installation from a port or package
local function perform_installation (action)
   local pkgname_old, pkgname_new, origin_new, pkgfile, automatic = action.pkg_old.name, action.pkg_new.name, action.origin_new.name, action.pkg_file, action.pkg_new.is_automatic
   local install_failed = false
   -- prepare installation, if this is an upgrade (and not a fresh install)
   if pkgname_old then
      if not Options.jailed or PHASE == "install" then
	 -- keep old package message for later comparison with new message
	 local pkg_msg_old = PkgDb.get_pkgmessage (action.pkgname_old)
	 -- create backup package file from installed files
	 if pkgname_old ~= pkgname_new or not action.pkgfile or not Package.file_valid_abi (action.pkgfile) then
	    Package.backup_create (pkgname_old) -- OUTPUT to MSGFILE if requested
	 end
	 -- preserve currently installed shared libraries
	 if Options.save_shared then
	    shlibs_backup (pkgname_old) -- OUTPUT
	 end
	 -- preserve pkg-static even when deleting the "pkg" package
	 if action.origin_new == "ports-mgmt/pkg" then
	    shell ("unlink", {as_root = true, PKG_CMD .. "~"})
	    shell ("ln", {as_root = true, PKG_CMD, PKG_CMD .. "~"})
	 end
	 -- delete old package version
	 Package.deinstall (action.pkgname_old) -- OUTPUT
	 -- restore pkg-static if it has been preserved
	 if origin_new == "ports-mgmt/pkg" then
	    shell ("unlink", {as_root = true, PKG_CMD})
	    shell ("mv", {as_root = true, PKG_CMD .. "~", PKG_CMD})
	 end
      end
   end
   if action.pkgfile then
      -- try to install from package
      Progress.show ("Install", action.pkg_new.name, "from a package")
      -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
      if not Package.install_jailed (action.pkgfile) then
	 -- OUTPUT
	 if not Options.jailed then
	    Package.deinstall (action.pkgname_new) -- OUTPUT
	    Package.recover (action.pkgname_old, action.automatic)
	 end
	 Progress.show ("Rename", action.pkg_file, "to", action.pkg_file ..".NOTOK after failed installation")
	 os.rename (action.pkg_file, action.pkg_file .. ".NOTOK")
	 return false
      end
   else
      -- try to install new port
      Progress.show ("Install", action.pkg_new.name, "built from", action.origin_new.name)
      -- <se> DEAL WITH CONFLICTS ONLY DETECTED BY PLIST CHECK DURING PKG REGISTRATION!!!
      if not action.origin_new:install () then
	 -- OUTPUT
	 deinstall_failed (action)
	 Package.recover (action.pkgname_old, action.automatic)
	 return false
      end
   end
   -- set automatic flag to the value the previous version had
   if automatic then
      PkgDb.automatic_set (action.pkgname_new, true)
   end
   -- register package name if package message changed
   local pkg_msg_new = PkgDb.get_pkgmessage (action.pkgname_new)
   if pkg_msg_old ~= pkg_msg_new then
      action.pkgmsg = pkg_msg_new -- package message returned as field in action record ???
   end
   -- remove all shared libraries replaced by new versions from shlib backup directory
   if Options.save_shared then
      shlibs_backup_remove_stale (pkgname_new) -- use action as argument???
   end
   -- delete stale package files
   if pkgname_old then
      if pkgname_old ~= pkgname_new then
	 Package.delete_old (pkgname_old)
	 if not Options.backup then
	    Package.backup_delete (pkgname_old)
	 end
      end
   end
   return true
end

-- peform delayed installation of ports not required as build dependencies after all ports have been built
local function perform_delayed_installation (action)
   action.pkgfile = Package.filename (PACKAGES .. "All", pkgname_new, Options.package_format)
   local taskmsg = action:describe ()
   Progress.show_task (taskmsg)
   assert (perform_installation (action), "Installation of $pkgname_new from $pkgfile failed")
   message_success_add (taskmsg)
end

-- ----------------------------------------------------------------------------------
-- perform all fetch and check operations
local function fetch_port (action)
   local origin = action.origin
   Msg.start (0, "Checking distfiles for", origin.name)
   assert (origin:wait_checksum ())
   action.done = true
   --Msg.cont (0, status)
end

local function perform_fetch_only ()
   for i, action in ipairs (WORKLIST) do
      action:fetch_port ()
   end
end

-- delete unused package and return TRUE, or add to delete queue if automatic but still referenced
local function package_deinstall_unused (action)
   local origin = action.origin_old
   local package = action.pkg.name
   if package then
      local status = PkgDb.query {jailed = true, "%a-%k-%#r", package}
      if status == "0-0-0" then
	 Package.deinstall (package)
	 Worklist.remove (origin)
	 DELAYED_DELETES[origin] = nil -- ??? check shell version !!!
	 for i, del_origin_name in DEP_DEL_AFTER_RUN[origin] do
	    DELAYED_DELETES[del_origin_name] = true
	 end
	 DEP_DEL_AFTER_RUN[origin] = nil
	 return true
      elseif strpfx (status, "0-0-") then
	 DELAYED_DELETES[origin] = true
	 Msg.cont (0, "Defer de-installation of", origin, "due to the following dependencies:")
	 Msg.cont (0, "\t" .. table.concat (PkgDb.query {jailed = true, "%rn-%rv", package}, "/n\t"))
      end
   end
   return false
end

local BUILDLOG = nil

-- delete obsolete packages
local function pkg_delete (action)
   perform_deinstall (action)
   action.done = true
end

local function perform_deletes ()
   -- delete obsolete packages (as indicated by the DELETES file)
   for i, action in ipairs (DELETES) do
      action:pkg_delete ()
   end
end

-- update changed port origin in the package db and move options file
local function origin_change (action)
   progress_show ("Change origin of", action.pkg_old.name, "from", action.origin_old.name, "to", action.origin_new.name)
   assert (PkgDb.update_origin (action.origin_old, action.origin_new, action.pkgname_old))
   portdb_update_origin (action.origin_old, action.origin_new)
   action.done = true
end

local function perform_origin_changes ()
   -- register new port origins (must come before package renames, if any)
   for i, action in ipairs (MOVES) do
      action:origin_change ()
   end
end

-- update package name of installed package
local function pkg_rename (action)
   progress_show ("Rename", pkgname_old, "to", pkgname_new)
   assert (PkgDb.update_pkgname (action.pkgname_old, action.pkgname_new), "Could not update registered package name from " .. pkgname_old .. " to " .. pkgname_new)
   pkgfiles_rename (action)
   action.done = true
end

local function perform_pkg_renames ()
   -- rename package in registry and in repository
   for i, action in ipairs (PKG_RENAMES) do -- or table_keys ???
      action:pkg_rename ()
   end
end

-- build (if required) and install packages
local function perform_upgrades ()
   -- install or upgrade required packages
   for i, origin_new in ipairs (WORKLIST) do
      origin_new = Origin:new (origin_new)
      Msg.start (0)
      -- if Options.hide_build is set the buildlog will only be shown on errors
      if Options.hide_build and not origin_new:port_var {"IS_INTERACTIVE"} then
	 BUILDLOG = tempfile_create ("BUILD_LOG")
      end
      if origin_new:perform_install_or_upgrade () then
	 tempfile_delete ("BUILD_LOG")
	 origin_new:perform_post_build_deletes ()
      else
	 if Options.hide_build then
	    shell_pipe ("cat > /dev/tty", BUILDLOG)
	 end
	 fail ("Aborting", PROGRAM, "due to a failed port upgrade. Fix the issue and use '" .. PROGRAM, "-R' to restart")
      end
   end
end

-- update repository database after creation of new packages
local function perform_repo_update ()
   -- create repository database
   Msg.start (0, "Create local package repository database ...")
   pkg {as_root = true, "repo", PACKAGES .. "All"}
end

-- perform delayed installations unless only the repository should be updated
local function perform_delayed_installations ()
   -- install upgraded packages
   --# Progress.set_max $NUM.DELAYED
   for i, origin_new in ipairs (DELAYED_INSTALL_LIST) do
      if not perform_delayed_installation (origin_new) then
	 fail "Delayed installation of $origin_new failed, aborting"
      end
      Worklist.remove_delayedlist (origin_new)
   end
end

-- ask user whether to delete packages that have been installed as dependency and are no longer required
local function packages_delete_stale ()
   local pkgnames_list = PkgDb.list_pkgnames ("%a==1 && %#r==0")
   for num, l in ipairs (pkgnames_list) do
      if l then
	 for i, pkgname in ipairs (l) do
	    if read_yn ("y", "Package " .. pkgname .." was installed as a dependency and does not seem to used anymore, delete") then
	       Package.perform_deinstall (pkgname)
	    else
	       if read_yn ("y", "Mark " .. pkgname .. " as 'user installed' to protect it against automatic deletion") then
		  PkgDb.automatic_set (pkgname, false)
	       end
	    end
	 end
      end
   end
end

-- ----------------------------------------------------------------------------------
-- deinstall packages that were only installed as build dependency
local function delete_build_only ()
   local oncemore = true
   while oncemore do
      oncemore = false
      for i, pkg_origins in pairs (PkgDb.list_pkgnames_origins ("%a==1 && %#r==0 && %k==0 && %V==0")) do
	 for j, pkg_origin in ipairs (pkg_origins) do
	    local pkgname = pkg_origin[1]
	    local origin = pkg_origin[2]
	    if origin then
	       local flavor = PkgDb.flavor_get (pkgname)
	       if flavor then
		  origin = origin .. "@" .. flavor
	       end
	       -- only packages (exclusively) used as build dependencies are to be deinstalled
	       if BUILDDEP[origin] and not RUNDEP[origin] then
		  if not Package.file_search (pkgname) then
		     Package.backup_create (pkgname)
		  end
		  Package.deinstall (pkgname)
		  oncemore = true
	       end
	    end
	 end
      end
   end
   Progress.clear ()
end

-- ----------------------------------------------------------------------------------
-- display actions that will be performed
local function show_tasks ()
   local num_actions = tasks_count ()
   if num_actions == 0 then
      Msg.start (0, "No action required")
   else
      Msg.start (0, "The following actions are required to perform the requested upgrade:")
      Progress.set_max (num_actions)
      Progress.list ("delete", DELETES)
      Progress.list ("move", MOVES)
      Progress.list ("rename", PKG_RENAMES)
      Progress.list ("upgrade", WORKLIST)
      local PHASE_SAVE = PHASE
      PHASE = "install"
      Progress.list ("upgrade", DELAYED_INSTALL_LIST)
      PHASE = PHASE_SAVE
   end
end

-- display statistics of actions to be performed
local function show_statistics ()
   local num_tasks
   local installed_txt, reinstalled_txt

   -- create statistics line from parameters
   function format_install_Msg.cont (num, action)
      if num and num > 0 then
	 local plural_s = num ~= 1 and "s" or ""
	 return string.format ("%5d %s%s %s", num, "package", plural_s, action)
      end
   end

   if not Options.repo_mode then
      installed_txt = "installed"
      reinstalled_txt = "re-installed"
   else
      installed_txt = "added"
      reinstalled_txt = "rebuilt"
   end
   num_tasks = tasks_count ()
   if num_tasks > 0 then
      Msg.start (0, "Statistic of planned actions:")
      Msg.cont (0, format_install_Msg.cont (NUM.deletes, "will be deleted"))
      Msg.cont (0, format_install_Msg.cont (NUM.moves + NUM.renames, "will be changed in the package registry"))
      Msg.cont (0, format_install_Msg.cont (NUM.provides, "will be loaded as build dependencies"))
      Msg.cont (0, format_install_Msg.cont (NUM.builds, "will be built"))
      Msg.cont (0, format_install_Msg.cont (NUM.reinstalls, "will be " .. reinstalled_txt))
      Msg.cont (0, format_install_Msg.cont (NUM.installs, "will be " .. installed_txt))
      Msg.cont (0, format_install_Msg.cont (NUM.upgrades, "will be upgraded"))
      Msg.start (0)
   end
end

-- 
local function execute ()
   show_tasks ()
   show_statistics ()
   if Options.fetch_only then
      if read_yn ("Fetch and check distfiles required for these upgrades now?", "y") then
	 -- wait for completion of fetch operations
	 perform_fetch_only ()
      end
   else
      Progress.clear ()
      if read_yn ("Perform these upgrades now?", "y") then
	 -- perform the planned tasks in the order recorded in WORKLIST
	 Msg.start (0)
	 Progress.set_max (tasks_count ())
	 perform_deletes ()
	 perform_origin_changes ()
	 perform_pkg_renames ()
	 if Options.jailed then
	    Jail.create ()
	 end
	 perform_upgrades ()
	 if Options.jailed then
	    Jail.destroy ()
	 end
	 Progress.clear ()
	 if Options.repo_mode then
	    perform_repo_update ()
	 else
	    if NUM.delayed > 0 then
	       PHASE = "install"
	       perform_delayed_installations ()
	    end
	 end
	 Progress.clear ()
      end
      PHASE = ""
   end
   return true
end

-- ----------------------------------------------------------------------------------
--[[
   local function derive_pkgname_old_from_origin_old (action)
   local function derive_pkgname_new_from_origin_new (action)
   local function derive_pkgname_new_from_origin_new_jailed (action)
   local function derive_pkgname_new_from_origin_old (action)
   local function derive_origin_new_from_origin_and_pkgname_old (action)
   local function derive_pkgname_old_from_origin_new (action)
   local function derive_origin_old_from_pkgname_old (action)
--]]
--
local function determine_pkg_old (self, k)
   local pt = self.origin_old and self.origin_old.old_pkgs
   if pt then
      local pkg_new = self.pkg_new
      if pkg_new then
	 local pkgnamebase = pkg_new.name_base
	 for i, p in ipairs (pt) do
	    if p.name_base == pkgnamebase then
	       return p
	    end
	 end
      end
   end
end

--
local function determine_pkg_new (self, k)
   local p = self.origin_new and self.origin_new.pkg_new
   if not p and self.origin_old and self.pkg_old then
      p = self.origin_old.pkg_new
      --[[
      if p and p.name_base_major ~= self.pkg_old.name_base_major then
	 p = nil -- further tests required !!!
      end
      --]]
   end
   return p
end

--
local function determine_pkg_file (self, k)
   local f = self.pkg_new and self.pkg_new.pkg_filename
   if f and access (f, "r") then
      return f
   end
end

--
local function determine_origin_old (self, k)
   --print ("OO:", self.pkg_old, (rawget (self, pkg_old) and (self.pkg_old).origin or "-"), self.pkg_new, (rawget (self, pkg_new) and (self.pkg_new.origin or "-")))
   local o = self.pkg_old and self.pkg_old.origin
      or self.pkg_new and self.pkg_new.origin -- NOT EXACT
   return o
end

--
local function verify_origin_new (o)
   if o and o.name and o.name ~= "" then
      local n = o.path .. "/Makefile"
      --print ("PATH", n)
      return access (n, "r")
   end
end

--
local function determine_origin_new (self, k)
   local o = rawget (self, pkg_new) and rawget (self.pkg_new, origin)
   --TRACE ("O_N_1", o and o.name) 
   if o and verify_origin_new (o) then
      return o
   end
   o = self.pkg_old and self.pkg_old.origin
   --TRACE ("O_N_2", o and o.name)
   if o then
      local o = Origin.lookup_moved_origin (o)
      --TRACE ("O_N_3", o and o.name)
      if o and o.reason or verify_origin_new (o) then
	 return o
      end
      --error ("Not a valid port directory: " .. o.path)
   end
   if o and verify_origin_new (o) then
      return o
   end
   return false
end

--
local function compare_versions (self, k)
   local p_o = self.pkg_old
   local p_n = self.pkg_new
   if p_o and p_n then
      if p_o == p_n then
	 return "="
      end
      return Exec.pkg {safe = true, "version", "-t", p_o.name, p_n.name}
   end
end

--
local function determine_action (action, k)
   local p_o = action.pkg_old
   local o_n = action.origin_new
   local o_o = action.origin_old
   local p_n = action.pkg_new
   local function need_upgrade ()
      if Options.force or action.build_type == "provide" or action.build_type == "checkabi" then
	 return true -- add further checks, e.g. changed dependencies ???
      end
      if p_o.version ~= p_n.version or o_o.flavor ~= o_n.flavor then
	 return true
      end
      if p_o == p_n then
	 return false
      end
      local pfx_o = string.match (p_o.name, "^([^-]+)-[^-]+-%S+")
      local pfx_n = string.match (p_n.name, "^([^-]+)-[^-]+-%S+")
      if pfx_o ~= pfx_n then
	 --print ("PREFIX MISMATCH:", pfx_o, pfx_n)
	 return true
      end
   end
   local function excluded ()
      if p_o and p_o.is_locked or p_n and p_n.is_locked then
	 return true -- ADD FURTHER CASES: excluded, broken without --try-broken, ignore, ...
      end
   end

   if excluded () then
      return "exclude"
   elseif not o_n then
      o_o.action = action
      return "delete"
   elseif not o_o or need_upgrade () then
      o_n.action = action
      return "upgrade"
   elseif o_o ~= o_n or p_o ~= p_n then
      o_n.action = action
      return "change"
   end
   return false
end

-- ----------------------------------------------------------------------------------
--local ACTIONS_CACHE = {}
local function __index (self, k)
   local function __depends (self, k)
      local o_n = self.origin_new
      if o_n then
	 k = string.match (k, "[^_]+")
	 return o_n.depends (self.origin_new, k)
      end
   end
   local dispatch = {
      pkg_old = determine_pkg_old,
      pkg_new = determine_pkg_new,
      pkg_file = determine_pkg_file,
      vers_cmp = compare_versions,
      origin_old = determine_origin_old,
      origin_new = determine_origin_new,
      build_depends = __depends,
      run_depends = __depends,
      action = determine_action,
   }

   TRACE ("INDEX(a)", k)
   local w = rawget (self.__class, k)
   if w == nil then
      rawset (self, k, false)
      local f = dispatch[k]
      if f then
	 w = f (self, k)
	 if w then
	    rawset (self, k, w)
	 else
	    w = false
	 end
      else
	 error ("illegal field requested: Action." .. k)
      end
      TRACE ("INDEX(a)->", k, w)
   else
      TRACE ("INDEX(a)->", k, w, "(cached)")
   end
   return w
end

-- object that controls the upgrading and other changes
local function new (Action, args)
   if args then
      TRACE ("ACTION", args.pkg_old or args.pkg_new or args.origin_new)
      local action = args
      action.__class = Action
      Action.__index = __index
      Action.__tostring = describe
      setmetatable (action, Action)
      return action
   else
      error ("Action:new() called with nil argument")
   end
end

--
ACTION_LIST = {} -- GLOBAL

local function add (args)
   local action = Action:new (args)
   if action.action then
      table.insert (ACTION_LIST, action)
      a = tostring (action)
      Msg.start (0, a)
      --[[
      --Dependencies???
	 local bd = action.build_depends or {}
	 print ("Build Depends:", table.unpack (bd))
	 local rd = action.run_depends or {}
	 print ("Run Depends:", table.unpack (rd))
      --]]
      --Add to Action-List???
   end
end

local function sort_list ()
   local sorted_list = {}
   local function add_action (action)
      if not rawget (action, "planned") then
	 --if action.action == "upgrade" then
	 for i, o in ipairs (action.build_depends or {}) do
	       local origin = Origin:new (o)
	       local a = origin.action
	       if a and not rawget (a, "planned") then
		  --print ("Build", a.origin_new, "for", action.origin_new or action.origin_old)
		  add_action (a)
	       end
	    end
	 --assert (not rawget (action, "planned"), "Dependency loop for " .. action.origin_new and action.origin_new.name or action.origin_old.name)
	    table.insert (sorted_list, action)
	    action.planned = true
	    Msg.cont (0, #sorted_list, " ", tostring (action))
	    for i, o in ipairs (action.run_depends or {}) do
	       local origin = Origin:new (o)
	       local a = origin.action
	       if a and not rawget (a, "planned") then
		  --print ("Provide", a.origin_new, "for", action.origin_new or action.origin_old)
		  add_action (a)
	       end
	    end
	 --end
      end
   end

   Msg.start (0, "Sort actions")
   for i, a in ipairs (ACTION_LIST) do
      Msg.start (0)
      add_action (a)
   end
   assert (#ACTION_LIST == #sorted_list, "ACTION_LIST items have been lost: " .. #ACTION_LIST .. " vs. " .. #sorted_list)
   ACTION_LIST = sorted_list
   --[[
   for i, a in ipairs (ACTION_LIST) do
      print (i, a)
   end
   --]]
end

-- ----------------------------------------------------------------------------------
--
return {
   new = new,
   execute = execute,
   packages_delete_stale = packages_delete_stale,
   register_delayed_installs = register_delayed_installs,
   add = add,
   sort_list = sort_list,
   --[[
   --]]
}

--[[
   Instance variables of class Action:
   - action = operation to be performed
   - origin = origin object (for port to be built)
   - origin_old = optional object (for installed port)
   - old_pkg = installed package object
   - new_pkg = new package object
   - done = status flag
--]]
