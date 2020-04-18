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
-- the Package class describes a package with optional package file

-- 
local function filename (pkg, args)
   local pkgname = pkg.name
   local base = args.base or PACKAGES
   local subdir = args.subdir or "All"
   local extension = args.ext or Options.package_format
   TRACE ("FILENAME", base, subdir, pkgname, extension, path_concat (basedir, subdir, pkgname .. "." .. extension))
   return path_concat (base, subdir, pkgname .. "." .. extension)
end

-- fetch ABI from package file
local function file_get_abi (pkg)
   pkg.abi = PkgDb.query {pkgfile = pkg.pkgfile, "%q"} -- <se> %q vs. %Q ???
end

-- check whether ABI of package file matches current system
local function file_valid_abi (pkg)
   file_get_abi (pkg)
   return pkg.abi == ABI or pkg.abi == ABI_NOARCH
end

-- return package version
local function pkg_version (pkg)
   local v = (string.match (pkg.name, ".*-([^-]+)"))
   TRACE ("VERSION", pkg.name, v)
   return v
end

-- return package basename without version
local function pkg_basename (pkg)
   return (string.match (pkg.name, "(%S+)-"))
end

-- return package name with only the first part of the version number
local function pkg_strip_minor (pkg)
   local major = string.match (pkg_version (pkg), "([^.]+)%.%S+")
   local result = pkg_basename (pkg) .. "-" .. (major or "")
   TRACE ("STRIP_MINOR", pkg.name, result)
   return result
end

-- ----------------------------------------------------------------------------------
-- deinstall named package (JAILED)
local function deinstall (package, make_backup)
   local pkgname = package.name
   if make_backup then
      Progress.show ("Create backup package for", pkgname)
      pkg {as_root = true, "create", "-q", "-o", PACKAGES_BACKUP, "-f", Options.backup_format, pkgname}
   end
   if Options.jailed and PHASE ~= "install" then
      Progress.show ("De-install", pkgname, "from build jail")
   else
      Progress.show ("De-install", pkgname)
   end
   return pkg {as_root = true, jailed = true, "delete", "-y", "-q", "-f", pkgname}
end

-- 
-- re-install package from backup after attempted installation of a new version failed
local function recover (pkg)
   -- if not pkgname then return true end
   local pkgname, pkgfile = pkg.name, pkg.pkgfile
   if not pkfile then
      pkgfile = Exec.shell {table = true, safe = true, "ls", "-1t", PACKAGES_BACKUP .. pkgname .. ".*"}[1] -- XXX replace with glob and sort by modification time
   end
   if pkgfile and access (pkgfile, "r") then
      Msg.cont (0, "Re-installing previous version", pkgname)
      if not install (pkgfile, file_get_abi (pkgfile)) then
	 Msg.cont (0, "Recovery from backup package failed")
	 return false
      end
      if pkg.is_automatic == 1 then
	 automatic_set (pkg, true)
      end
      shlibs_backup_remove_stale (pkg)
      Exec.run {as_root = true, "/bin/unlink", PACKAGES_BACKUP .. pkgname_old .. ".t??"}
      return true
   end
end

-- search package file
local function file_search (pkg)
   local filename
   for d in ipairs ({"All", "package-backup"}) do
      for f in glob (pkg:filename {subdir = d, ext = ".t??"}) do
	 if packagefile_valid_abi (f) then
	    if not filename or stat (filename).modification < stat (f).modification then
	       filename = f
	    end
	 end
      end
      if filename then
	 return filename
      end
   end
end

-- delete backup package file
local function backup_delete (pkg)
   local g = pkg:filename {base = PACKAGES_BACKUP, ext = ".t??"}
   for i, backupfile in pairs (glob (g) or {}) do
      TRACE ("BACKUP_DELETE", backupfile, PACKAGES .. "portmaster-backup/")
      Exec.run {as_root = true, "/bin/unlink", backupfile}
   end
end

-- delete stale package file
local function delete_old (pkg)
   local g = pkg:filename {subdir = "*", ext = "t??"}
   TRACE ("DELETE_OLD", pkg.name, g)
   for i, pkgfile in pairs (glob (g) or {}) do
      TRACE ("CHECK_BACKUP", pkgfile, PACKAGES .. "portmaster-backup/")
      if not string.match (pkgfile, "^" .. PACKAGES .. "portmaster-backup/") then
	 Exec.run {as_root = true, "/bin/unlink", pkgfile}
      end
   end
end

-- ----------------------------------------------------------------------------------
-- remove from shlib backup directory all shared libraries replaced by new versions
-- preserve currently installed shared libraries // <se> check name of control variable
function shlibs_backup (pkg)
   local pkg_libs = pkg.shared_libs
   if pkg_libs then
      local ldconfig_lines = Exec.run {table = true, safe = true, LDCONFIG_CMD, "-r"} -- "RT?" ??? CACHE LDCONFIG OUTPUT???
      for i, line in ipairs (ldconfig_lines) do
	 local libpath, lib = string.match (line, " => (" .. LOCAL_LIB .. "*(lib.*%.so%..*))")
	 if lib then
	    if stat_isreg (lstat (libpath).st_mode) then
	       for i, l in ipairs (pkg_libs) do
		  if l == lib then
		     local backup_lib = LOCAL_LIB_COMPAT .. lib
		     if access (backup_lib, "r") then
			Exec.run {as_root = true, to_tty = true, "/bin/unlink", backup_lib}
		     end
		     Exec.run {as_root = true, "/bin/cp", libpath, backup_lib}
		  end
	       end
	    end
	 end
      end
   end
end

-- remove from shlib backup directory all shared libraries replaced by new versions
local function shlibs_backup_remove_stale (pkg)
   local pkg_libs = pkg.shared_libs
   if pkg_libs then
      local deletes = {}
      for i, lib in ipairs (pkg_libs) do
	 local backup_lib = LOCAL_LIB_COMPAT .. lib
	 if access (backup_lib, "r") then
	    table.insert (deletes, backup_lib)
	 end
      end
      if #deletes > 0 then
	 Exec.run {as_root = true, "/bin/rm", "-f", table.unpack (deletes)}
	 Exec.run {as_root = true , LDCONFIG_CMD, "-R"}
      end
      return true
   end
end

-- ----------------------------------------------------------------------------------
-- install package from passed filename
local function install (pkg)
   local pkgfile, abi = pkg.pkgfile, pkg.abi
   local args = {"add", "-M", pkgfile, as_root = true, to_tty = true}
   if pkgfile:match (".*/pkg-[^/]+$") then -- ports/pkg
      if not access (PKG_CMD, "x") then
	 Exec.run {as_root = true, to_tty = true, env = {"ASSUME_ALWAYS_YES=yes"}, "/usr/sbin/pkg", "-v"}
      end
      args.env = {SIGNATURE_TYPE = "none"}
   elseif abi then
      args.env = {ABI = abi}
   end
   return Exec.pkg (args)
end

-- install package from passed filename in jail
local function install_jailed (pkg)
   local pkgfile = pkg.filename
   return pkg {jailed = true, "add", "-M", pkgfile}
end

-- create category links and a lastest link
local function category_links_create (pkg_new, categories)
   local source = pkg_new:filename {base = "..", ext = extension}
   local pkgname = pkg_new.name
   local extension = Options.package_format
   table.insert (categories, "Latest")
   for i, category in ipairs (categories) do
      local destination = PACKAGES .. category
      if not is_dir (destination) then
	 Exec.run {as_root = true, "mkdir", "-p", destination}
      end
      if category == "Latest" then
	 destination = destination .. "/" .. pkg_new.name_base .. "." .. extension
      end
      Exec.run {as_root = true, "ln", "-sf", source, destination}
   end
end

-- ----------------------------------------------------------------------------------
-- return true (exit code 0) if named package is locked
-- set package to auto-installed if automatic == 1, user-installed else
local function automatic_set (pkg, automatic)
   local value = automatic and "1" or "0"
   PkgDb.set ("-A", value, pkg.name)
end

-- check whether package is on includes list
local function check_excluded (pkg)
   return Excludes.check_pkg (pkg)
end

-- check package name for possibly used default version parameter
local function check_default_version (origin_name, pkgname)
   local T = {
      apache = "^apache(%d)(%d)-",
      llvm= "^llvm(%d%d)-",
      --lua = "^lua(%d)(%d)-",
      mysql = "^mysql(%d)(%d)-",
      pgsql = "^postgresql(9)(%d)-",
      pgsql1 = "^postgresql1(%d)-",
      php = "^php(%d)(%d)-",
      python2 = "^py(2)(%d)-",
      python3 = "^py(3)(%d)-",
      ruby = "^ruby(%d)(%d)-",
      tcltk = "^t[ck]l?(%d)(%d)-",
   }
   TRACE ("DEFAULT_VERSION", origin_name, pkgname)
   for prog, pattern in pairs (T) do
      local major, minor = string.match (pkgname, pattern)
      if major then
	 local default_version = prog .. "=" .. (minor and major .. "." .. minor or major)
	 origin_name = origin_name .. "%" .. default_version
	 TRACE ("DEFAULT_VERSION->", origin_name, pkgname)
      end
   end
   return origin_name
end

-- ----------------------------------------------------------------------------------
local PACKAGES_CACHE = {} -- should be local with iterator ...
local PACKAGES_CACHE_LOADED = false -- should be local with iterator ...
--setmetatable (PACKAGES_CACHE, {__mode = "v"})

local function shared_libs_cache_load ()
   Msg.start (2, "Load list of provided shared libraries")
   local p = {}
   local lines = PkgDb.query {table = true, "%n-%v %b"}
   for i, line in ipairs (lines) do
      local pkgname, lib = string.match (line, "^(%S+) (%S+%.so%..*)")
      if pkgname then
	 if pkgname ~= rawget (p, "name") then
	    p = Package:get (pkgname) -- fetch cached package record
	    p.shared_libs = {}
	 end
	 table.insert (p.shared_libs, lib)
      end
   end
   Msg.cont (2, "The list of provided shared libraries has been loaded")
   Msg.start (2)
end

local function req_shared_libs_cache_load ()
   Msg.start (2, "Load list of required shared libraries")
   local p = {}
   local lines = PkgDb.query {table = true, "%n-%v %B"}
   for i, line in ipairs (lines) do
      local pkgname, lib = string.match (line, "^(%S+) (%S+%.so%..*)")
      if pkgname then
	 if pkgname ~= rawget (p, "name") then
	    p = Package:get (pkgname) -- fetch cached package record
	    p.req_shared_libs = {}
	 end
	 table.insert (p.req_shared_libs, lib)
      end
   end
   Msg.cont (2, "The list of required shared libraries has been loaded")
   Msg.start (2)
end

-- load a list of of origins with flavor for currently installed flavored packages
local function packages_cache_load ()
   if PACKAGES_CACHE_LOADED then
      return
   end
   local pkg_flavor = {}
   local pkg_fbsd_version = {}
   Msg.start (2, "Load list of installed packages ...")
   local lines = PkgDb.query {table = true, "%At %Av %n-%v"}
   if lines then
      for i, line in pairs (lines) do
	 local tag, value, pkgname = string.match (line, "(%S+) (%S+) (%S+)")
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
   for i, line in ipairs (lines) do
      local pkgname, origin_name, abi, automatic, locked = string.match (line, "(%S+) (%S+) (%S+) (%d) (%d)")
      local f = pkg_flavor[pkgname]
      if f then
	 origin_name = origin_name .. "@" .. f
      else
	 origin_name = check_default_version (origin_name, pkgname)
      end
      local p = Package:new (pkgname)
      local o = Origin:new (origin_name)
      if not rawget (o, "old_pkgs") then
	 o.old_pkgs = {}
      end
      o.old_pkgs[pkgname] = true
      p.origin = o
      p.abi = abi
      p.is_automatic = automatic == "1"
      p.is_locked = locked == "1"
      p.is_installed = true
      p.num_depending = 0
      p.dep_pkgs = {}
      p.fbsd_version = pkg_fbsd_version[pkgname]
      pkg_count = pkg_count + 1
   end
   Msg.cont (2, "The list of installed packages has been loaded (" .. pkg_count .. " packages)")
   Msg.start (2, "Load package dependencies")
   local p = {}
   local lines = PkgDb.query {table = true, "%n-%v %rn-%rv"}
   for i, line in ipairs (lines) do
      local pkgname, dep_pkg = string.match (line, "(%S+) (%S+)")
      if pkgname ~= rawget (p, "name") then
	 p = Package:get (pkgname) -- fetch cached package record
	 p.dep_pkgs = {}
      end
      p.num_depending = p.num_depending + 1
      table.insert (p.dep_pkgs, dep_pkg)
   end
   Msg.cont (2, "Package dependencies have been loaded")
   Msg.start (2)
   shared_libs_cache_load ()
   req_shared_libs_cache_load ()
   PACKAGES_CACHE_LOADED = true
end

-- add reverse dependency information (who depends on me?)
DEP_PKGS_CACHE_LOADED = false

local function dep_pkgs_cache_load (pkg, k)
   if not DEP_PKGS_CACHE_LOADED then
      DEP_PKGS_CACHE_LOADED = true
   end
   return rawget (pkg, k)
end

-- 
local function get (pkg, name)
   return PACKAGES_CACHE[name]
end

-- 
local function installed_pkgs ()
   packages_cache_load ()
   local result = {}
   for k, v in pairs (PACKAGES_CACHE) do
      if v.is_installed then
	 table.insert (result, PACKAGES_CACHE[k])
      end
   end
   return result
end

-- 
local function get_attribute (pkg, k)
   for i, v in ipairs (PkgDb.query {table = true, "%At %Av", pkg.name}) do
      local result = string.match (v, "^" .. k .. " (.*)")
      if result then
	 return result
      end
   end
end

--
local function __newindex (pkg, n, v)
   TRACE ("SET(p)", pkg.name, n, v)
   rawset (pkg, n, v)
end

local function __index (pkg, k)
   local function __pkg_vars (pkg, k)
      local function set_field (field, v)
	 if v == "" then v = false end
	 pkg[field] = v
      end
      local t = PkgDb.query {table = true, "%q\n%k\n%a\n%#r", pkg.name_base}
      set_field ("abi", t[1])
      set_field ("is_locked", t[2] == "1")
      set_field ("is_automatic", t[3] == "1")
      set_field ("num_depending", tonumber (t[4]))
      return pkg[k]
   end
   function load_num_dependencies (pkg, k)
      Msg.start (2, "Load dependency counts")
      local t = PkgDb.query {table = true, "%#d %n-%v"}
      for i, line in ipairs (t) do
	 local num_dependencies, pkgname = string.match (line, "(%d+) (%S+)")
	 PACKAGES_CACHE[pkgname].num_dependencies = tonumber (num_dependencies)
      end
      Msg.cont (2, "Dependency counts have been loaded")
      Msg.start (2)
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
      dep_pkgs = dep_pkgs_cache_load,
      shared_libs = function (pkg, k)
	 return PkgDb.query {table = true, "%b", pkg.name}
      end,
      req_shared_libs = function (pkg, k)
	 return PkgDb.query {table = true, "%B", pkg.name}
      end,
      is_installed = function (pkg, k)
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
      shlibs = function (pkg, k)
	 error ("should be cached")
	 return PkgDb.query {table = true, "%B", pkg.name}
      end,
      --]]
      pkgfile = function (pkg, k)
	 return pkg:filename {subdir = "All"}
      end,
      bakfile = function (pkg, k)
	 return pkg:filename {subdir = "portmaster-backup", ext = Options.backup_format}
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
   
   TRACE ("INDEX(p)", pkg, k)
   local w = rawget (pkg.__class, k)
   if w == nil then
      rawset (pkg, k, false)
      local f = dispatch[k]
      if f then
	 w = f (pkg, k)
	 if w then
	    rawset (pkg, k, w)
	 else
	    w = false
	 end
      else
	 error ("illegal field requested: Package." .. k)
      end
      TRACE ("INDEX(p)->", pkg, k, w)
   else
      TRACE ("INDEX(p)->", pkg, k, w, "(cached)")
   end
   return w
end

-- create new Package object or return existing one for given name
local function new (pkg, name)
   --local TRACE = print -- TESTING
   assert (type (name) == "string", "Package:new (" .. type (name) .. ")")
   if name then
      local P = PACKAGES_CACHE[name]
      if not P then
	 P = {name = name}
	 P.__class = pkg
	 pkg.__index = __index
	 pkg.__newindex = __newindex -- DEBUGGING ONLY
	 pkg.__tostring = function (pkg)
	    return pkg.name
	 end
	 --pkg.__eq = function (a, b) return a.name == b.name end
	 setmetatable (P, pkg)
	 PACKAGES_CACHE[name] = P
	 TRACE ("NEW Package", name)
      else
	 TRACE ("NEW Package", name, "(cached)")
      end
      return P
   end
   return nil
end

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache ()
   local t = PACKAGES_CACHE
   for i, v in ipairs (table.keys (t)) do
      local name = tostring (v)
      TRACE ("PACKAGES_CACHE", name, table.unpack (table.keys (t[v])))
   end
end

-- ----------------------------------------------------------------------------------
return {
   name = false,
   new = new,
   get = get,
   installed_pkgs = installed_pkgs,
   backup_delete = backup_delete,
   backup_create = backup_create,
   delete_old = delete_old,
   recover = recover,
   category_links_create = category_links_create,
   file_search = file_search,
   pkg_filename = pkg_filename,
   --file_get_abi = file_get_abi,
   file_valid_abi = file_valid_abi,
   check_use_package = check_use_package,
   check_excluded = check_excluded,
   deinstall = deinstall,
   install_jailed = install_jailed,
   install = install,
   shlibs_backup = shlibs_backup,
   shlibs_backup_remove_stale = shlibs_backup_remove_stale,
   automatic_set = automatic_set,
   packages_cache_load = packages_cache_load,
   dump_cache = dump_cache,
}

--[[
   Instance variables of class Package:
   - abi = abi of package as currently installed
   - categories = table of registered categories of this package
   - files = table of installed files of this package
   - pkg_filename = name of the package file
   - bak_filename = name of the backup file
   - shlibs = table of installed shared libraries of this package
   - is_automatic = boolean value whether this package has been automaticly installed
   - is_locked = boolean value whether this package is locked
   - num_dependencies = the number of packages required to run this package
   - num_depending = the number of other packages that depend on this one
   - origin = the origin string this package has been built from
--]]
