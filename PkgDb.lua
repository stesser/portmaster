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
-- query package DB for passed origin (with optional flavor) or passed package name
-- <se> actually not working for origin with flavor due to lack of transparent support in "pkg"
local function query (args) -- optional extra argument: pkgname or origin
   if args.cond then
      table.insert (args, 1, "-e")
      table.insert (args, 2, cond)
   end
   if args.pkgfile then
      table.insert (args, 1, "-F")
      table.insert (args, 2, args.pkgfile)
   end
   if args.glob then
      table.insert (args, 1, "-g")
   end
   table.insert (args, 1, "query")
   args.safe = true
   return Exec.pkg (args)
end

-- get package information from pkgdb
local function info (...)
   return Exec.pkg {safe = true, table = true, "info", "-q", ...}
end

-- set package attribute for specified ports and/or packages
local function set (...)
   return Exec.pkg {as_root = true, "set", "-y", ...}
end

-- get package message in case of an installation to the base system
local function get_pkgmessage (pkgname)
   if not Options.dry_run and (not Options.jailed or PHASE == "install") then
      local lines = PkgDb.query {table = true, "%M", pkgname}
      if lines then
	 return table.concat (lines, "\n")
      end
   end
end

-- get the annotation value (e.g. flavor), if any
local function annotate_get (var, name)
   assert (var, "no var passed")
   return Exec.pkg {safe = true, "annotate", "-Sq", name, var}
end

-- set the annotation value, or delete it if "$value" is empty
local function annotate_set (var, name, value)
   local opt = value and #value > 0 and "-M" or "-D"
   return Exec.pkg {as_root = true, "annotate", "-qy", opt, name, var, value}
end

-- ---------------------------------------------------------------------------
-- lookup flavor of given package in the package database
local function flavor_get (pkgname)
   local result = annotate_get ("flavor", pkgname)
   if result ~= "" then
      return result
   end
end

-- set flavor of given package in the package database
local function flavor_set (pkgname, flavor)
   annotate_set ("flavor", pkgname, flavor)
end

-- check flavor of given package in the package database
local function flavor_check (pkgname, flavor)
   return flavor_get (pkgname) == flavor
end

-- list ports that are currently installed and not a dependency of some other port
local function list_origins ()
   local pkgname
   flavored_cache_load ()
   for i, pkgname in ipairs (PkgDb.query {table = true, cond = "%#r==0", "%n-%v"}) do
      io.stdout:write (origin_from_pkgname (pkgname), "\n")
   end
end

-- return list of all installed packages that meet the condition, order by decreasing number of dependencies
local function list_pkgnames (condition)
   local list = {}
   for i, line in ipairs (PkgDb.query {table = true, cond = condition, "%#d %n-%v"}) do
      local num, pkg = line:match ("(%d+) (%S+)")
      if not list[num] then
	 list[num] = {}
      end
      table.insert (list[num], pkg)
   end
   return list
end

-- return registered name and origin
local function list_pkgnames_origins (condition)
   local list = {}
   for i, line in pairs (PkgDb.query {table = true, cond = condition, "%#d %n-%v %o"}) do
      local depends, pkgname, port = line:match ("(%d+) (%S+) (%S+)")
      depends = depends + 0
      -- work around the fact that pkg query "%o" does not include the flavor
      if not list[depends] then
	 list[depends] = {}
      end
      table.insert (list[depends], {pkgname, flavored_cache_get_origin (port, pkgname)})
   end
   return list
end

-- search a registered port with same name and near-by version number
local function nearest_pkgname (pkgname_new)
   local pkgname_nov = Package.basename (pkgname_new)
   local version = Package.version (pkgname_new)
   local pkgnames = PkgDb.query {table = true, "%n-%v", pkgname_nov}
   if not pkgnames then
      return nil
   end
   while #version > 0 do
      for i, pkgname in ipairs (pkgnames) do
	 if strpfx (pkgname, pkgname_nov .. "-" .. version) then
	    return pkgname
	 end
      end
      if string.find (version, ".", 1, true) then
	 version = version:gsub("%.[^.]+$", "")
      else
	 version = ""
      end
   end
   return nil
end

-- return origin if found in the package registry
local function origin_from_pkgname (pkgname)
   local flavor = ""
   flavor = PkgDb.flavor_get (pkgname)
   flavor = flavor and "@" .. flavor or ""
   return PkgDb.query {"%o" .. flavor, pkgname}
end

-- return origin for package glob if it is unique in the package registry
local function origin_from_pkgname_glob (pkgname)
   local pkgnames = PkgDb.query {table = true, glob = true, "%n-%v", pkgname}
   if pkgnames[2] then
      return nil
   end -- not unique
   return pkgdb_origin_from_pkgname (pkgnames[1])
end

-- -- ???
-- list origins with optional flavor for ports or packages matching a glob pattern
local function origins_flavor_from_glob (param)
   local glob = dir_part (param)
   local flavor = flavor_part (param)
   -- 	local pkgname matches
   local matches = {}
   for i, pkgname in PkgDb.query {table = true, glob = true, "%n-%v", glob} do
      if not flavor or PkgDb.flavor_check (pkgname, flavor) then
	 local origin = pkgdb_origin_from_pkgname (pkgname)
	 if origin then
	    matches:insert (Origin:new (origin))
	 end
      end
   end
   return matches
end

-- return pkgname(s) for origin (with optional flavor)
-- <se> MOVED ORIGIN HANDLING MUST BE PERFORMED BY CALLERS!!!
local function pkgname_from_origin (origin)
   local dir = origin.port
   local flavor = origin.flavor
   local pkgname

   if not dir then
      return nil
   end
   -- [ -n "$OPT_jailed" ] && return 1 # assume PHASE=build: the jails are empty, then
   result = {}
   if flavor then
      local lines = PkgDb.query {table = true, "%At %Av %n-%v", dir}
      if lines then
	 for line in ipairs (lines) do
	    local tag, value, pkgname = string.match (line, "(%S+) (%S+) (%S+)")
	    if tag == "flavor" and value == flavor then
	       local p = Package:new (pkgname)
	       if rawget (p, "origin") then -- paranoid test
		  assert (p.origin == origin)
	       end
	       p.origin = origin
	       table.insert (result, p)
	    end
	 end
      end
   else
      local pkgnames = PkgDb.query {table = true, "%At %Av %n-%v", dir}
      for i, line in ipairs (pkgnames) do
	 local tag, value, pkgname = string.match (line, "(%S+) (%S+) (%S+)")
	 local p = Package:new (pkgname)
	    if rawget (p, "origin") then -- paranoid test
	       assert (p.origin == origin)
	    end
	 p.origin = origin
	 table.insert (result, p)
      end
   end
   return result
end

-- rename package in package DB (including all dependencies on this package)
local function update_pkgname (action)
   local pkg_old = action.pkgname_old:basename ()
   local pkg_new = action.pkgname_new:basename ()
   
   -- compare package name without the version, which is stored in another attribute                                                                                                                  
   if pkg_old == pkg_new then
      return true
   end
   return PkgDb.set ("--change-name", pkg_old .. ":" .. pkg_new, tostring (action.pkgname_old))
end

-- register new origin in package registry (must be performed before package rename, if any)
local function update_origin (old, new, pkgname)
   local dir_old = old:port ()
   local dir_new = new:port ()
   local flavor = new:flavor ()

   if dir_old ~= dir_new then
      if not PkgDb.set ("--change-origin", dir_old .. ":" .. dir_new, pkgname) then
	 return false, "Could not change origin of " .. tostring (pkgname) .. " from " .. dir_old .. " to " .. dir_new
      end
   end
   if not PkgDb.flavor_check (pkgname, flavor) then
      if not PkgDb.flavor_set (pkgname, flavor) then
	 return false, "Could not set flavor of " .. tostring (pkgname) .. " to " .. flavor
      end
   end
   return true
end

return {
   query = query,
   info = info,
   set = set,
   flavor_get = flavor_get,
   flavor_set = flavor_set,
   flavor_check = flavor_check,
   get_pkgmessage = get_pkgmessage,
   list_origins = list_origins,
   list_pkgnames = list_pkgnames,
   list_pkgnames_origins = list_pkgnames_origins,
   update_origin = update_origin,
   nearest_pkgname = nearest_pkgname,
   origin_from_pkgname = origin_from_pkgname,
   origin_from_pkgname_glob = origin_from_pkgname_glob,
   origins_flavor_from_glob = origins_flavor_from_glob,
   pkgname_from_origin = pkgname_from_origin,
}
