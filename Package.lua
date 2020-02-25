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

-- return package file name in PACKAGES/<dir>
local function filename (basedir, pkgname, extension)
   TRACE ("filename", basedir, pkgname, extension)
   return basedir .. "/" .. pkgname .. "." .. extension
end

-- 
local function pkg_filename (args)
   local pkg = args[1]
   local pkgname = pkg.name
   local subdir = args.subdir or "All"
   local extension = args.ext or Options.package_format
   return PACKAGES .. subdir .. "/" .. pkgname .. "." ..extension
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
local function deinstall (pkg, make_backup)
   local pkgname = pkg.name
   if make_backup then
      progress_show ("Create backup package for", pkgname)
      pkg {as_root = true, "create", "-q", "-o", PACKAGES_BACKUP, "-f", Options.backup_format, pkgname}
   end
   if Options.jailed and PHASE ~= "install" then
      progress_show ("De-install", pkgname, "from build jail")
   else
      progress_show ("De-install", pkgname)
   end
   return pkg {as_root = true, jailed = true, "delete", "-y", "-q", "-f", pkgname}
end

-- 
-- re-install package from backup after attempted installation of a new version failed
local function recover (pkg)
   -- if not pkgname then return true end
   local pkgname, automatic, pkgfile = pkg.name, pkg.automatic, pkg.pkgfile
   if not pkfile then
      pkgfile = Exec.shell ("ls", {table = true, safe = true, "-1t", PACKAGES_BACKUP .. pkgname .. ".*"})[1]
   end
   if pkgfile and access (pkgfile, "r") then
      Msg.cont (0, "Re-installing previous version", pkgname)
      if install (pkgfile, file_get_abi (pkgfile)) then
	 if automatic == 1 then
	    PkgDb.automatic_set (pkgname_old, true)
	 end
	 shlibs_backup_remove_stale (pkgname_old)
	 Exec.run ("/bin/unlink", {as_root = true, PACKAGES_BACKUP .. pkgname_old .. ".t??"})
	 return true
      else
	 Msg.cont (0, "Recovery from backup package failed")
	 return false
      end
   end
end

-- create category links and a lastest link
local function category_links_create (pkg)
   local pkgname = pkg.name
   local extension = pkgname:gsub (".+%.", "")
   local pkgname = pkgname:gsub (".*/(%S+)%.[^.]+", "%1")
   local categories = PkgDb.query {table = true, "%C", pkgname}
   table.insert (categories, "Latest")
   for i, category in ipairs (categories) do
      local destination = PACKAGES .. category
      if not is_dir (destination) then
	 Exec.run ("mkdir", {as_root = true, "-p", destination})
      end
      if category == "Latest" then
	 destination = destination .. "/" .. pkgname:gsub ("(.*)-.*", "%1") .. "." .. extension
      end
      Exec.run ("ln", {as_root = true, "-sf", "../" .. filename ("All", pkgname, extension), destination})
   end
end

-- search package file
local function file_search (pkg)
   local filename
   for d in ipairs ({"All", "package-backup"}) do
      for f in glob (package_filename (PACKAGES .. d, pkg.name, ".t??")) do
	 if packagefile_valid_abi (f) then
	    if not filename or stat (filename).modification < stat (f).modification then
	       filename = f
	    end
	 end
      end
      if filename then return filename end
   end
end

-- delete backup package file
local function backup_delete (pkg)
   local backupfile = filename (PACKAGES_BACKUP, pkg.name, ".t??")
   return Exec.run ("/bin/unlink", {as_root = true, backupfile})
end

-- delete stale package file
local function delete_old (pkg)
   local pkgname_old = pkg.pkg_old.name
   local g = filename (PACKAGES .. "*", pkgname_old, "t??")
   --print ("GLOB", g)
   for pkgfile in glob (PACKAGES .. filename ("*", pkgname_old, "t??")) do
      Exec.run ("unlink", {as_root = true, pkgfile})
   end
end

-- ----------------------------------------------------------------------------------
-- remove from shlib backup directory all shared libraries replaced by new versions
-- preserve currently installed shared libraries // <se> check name of control variable
function shlibs_backup (pkg)
   local pkg_libs = PkgDb.query {table = true, "%Fp", pkg.name}
   if pkg_libs then
      local ldconfig_lines = Exec.run (LDCONFIG_CMD, {table = true, safe = true, "-r"}) -- "RT?" ???
      for i, line in ipairs (ldconfig_lines) do
	 if line:match("^" .. LOCAL_LIB .. "/lib.*[.]so[.]") then
	    local lib = line:match (" => (%S+)")
	    if lib then
	       for i, l in ipairs (pkg_libs) do
		  if l:match ("^" .. LOCAL_LIB_COMPAT) and l == lib then
		     local backup_lib = LOCAL_LIB_COMPAT .. "/" .. lib:gsub(".*/", "")
		     if Exec.run ("/bin/unlink", {as_root = true, to_tty = true, backup_lib}) then
			Exec.run ("/bin/cp", {as_root = true, lib, backup_lib})
		     end
		  end
	       end
	    end
	 end
      end
   end
end

-- remove from shlib backup directory all shared libraries replaced by new versions
local function shlibs_backup_remove_stale (pkg)
   local pkg_libs = PkgDb.query {table = true, "%Fp", pkg.name}
   if not pkg_libs then
      return nil
   end
   local deletes = {}
   for i, lib in ipairs (pkg_libs) do
      local backup_lib = LOCAL_LIB_COMPAT .. "/" .. lib:gsub(".*/", "")
      if access (backup_lib, "r") then
	 table.insert (deletes, backup_lib)
      end
   end
   if #deletes > 0 then
      Exec.run ("/bin/rm", {as_root = true, "-f", table.unpack (deletes)})
      Exec.run (LDCONFIG_CMD, {as_root = true , "-R"})
   end
   return true
end

-- ----------------------------------------------------------------------------------
-- install package from passed filename
local function install (pkg)
   local pkgfile, abi = pkg.pkgfile, pkg.abi
   local args = {"add", "-M", pkgfile, as_root = true, to_tty = true}
   if pkgfile:match (".*/pkg-[^/]+$") then -- ports/pkg
      if not access (PKG_CMD, "x") then
	 Exec.run ("/usr/sbin/pkg", {as_root = true, to_tty = true, env = {"ASSUME_ALWAYS_YES=yes"}, "-v"})
      end
      args.env = {SIGNATURE_TYPE = "none"}
   elseif abi then
      args.env = {ABI = abi}
   end
   return Exec.pkg (args)
end

-- install package from passed filename in jail
local function install_jailed (pkg)
   local pkgfile = pkg.pkg_filename
   return pkg {jailed = true, "add", "-M", pkgfile}
end

-- ----------------------------------------------------------------------------------
-- return true (exit code 0) if named package is locked
-- set package to auto-installed if automatic == 1, user-installed else
local function automatic_set (pkg)
   PkgDb.set ("-A", pkg.automatic, pkg.name)
end

-- get auto-installed status
local function automatic_get (pkg)
   pkg.automatic = PkgDb.query {"%a", pkg.name}
end

-- return true (exit code 0) if named package was only installed as a dependency
local function automatic_check (pkg)
   automatic_get (pkg)
   return pkg.automatic == "1"
end

-- check whether package is on includes list
local function check_excluded (pkg)
   return Excludes.check_pkg (pkg.name)
end

-- 
local T = {
   apache = "^apache(%d)(%d)-",
   llvm= "^llvm(%d%d)-",
   lua = "^lua(%d)(%d)-",
   mysql = "^mysql(%d)(%d)-",
   pgsql = "^postgresql(9)(%d)-",
   pgsql1 = "^postgresql1(%d)-",
   php = "^php(%d)(%d)-",
   python2 = "^py(2)(%d)-",
   python3 = "^py(3)(%d)-",
   ruby = "^ruby(%d)(%d)-",
   tcltk = "^t[ck]l?(%d)(%d)-",
   --[[
      ssl=openssl111
      ssl=base
   --]]
}

-- check package name for possibly used default version parameter
local function check_used_default_version (pkg)
   local function compare (name, pattern, prog)
      local major, minor = string.match (name, pattern)
      if major then
	 local version = minor and major .. "." .. minor or major
	 return prog .. "=" .. version
      end
   end
   local name = pkg.name
   TRACE ("DEFAULT_VERSION", name)
   if name then
      for k, v in pairs (T) do
	 local result = compare (name, v, k)
	 if result then
	    if DEFAULT_VERSIONS[result] then
	       result = nil -- identified version is default version
	    end
	    TRACE ("DEFAULT_VERSION->", name, result)
	    return result
	 end
      end
   else
      error ("Package name has not been set!")
   end
end

-- ----------------------------------------------------------------------------------
local PACKAGES_CACHE = {} -- should be local with iterator ...
local PACKAGES_CACHE_LOADED = false -- should be local with iterator ...
--setmetatable (PACKAGES_CACHE, {__mode = "v"})

-- load a list of of origins with flavor for currently installed flavored packages
local function packages_cache_load ()
   local pkg_flavors = {}
   if not PACKAGES_CACHE_LOADED then
      Msg.cont (1, "Load list of installed packages ...")
      local lines = PkgDb.query {table = true, "%At %Av %n-%v"}
      if lines then
	 for i, line in pairs (lines) do
	    local tag, flavor, pkgname = string.match (line, "(%S+) (%S+) (%S+)")
	    if tag == "flavor" then
	       pkg_flavors[pkgname] = flavor
	    end
	 end
      end
      -- load 
      local pkg_count = 0
      local p = {}
      lines = PkgDb.query {table = true, "%n-%v %o %q %a %k"} -- no dependent packages
      for i, line in ipairs (lines) do
	 local pkgname, origin, abi, automatic, locked = string.match (line, "(%S+) (%S+) (%S+) (%d) (%d)")
	 p = PACKAGES_CACHE[pkgname] or Package:new (pkgname)
	 local f = pkg_flavors[pkgname]
	 local pf = check_used_default_version (p)
	 origin = f and origin .. "@" .. f or origin
	 origin = pf and origin .. "%" .. pf or origin
	 local o = Origin:new (origin)
	 if not rawget (o, "old_pkgs") then
	    o.old_pkgs = {}
	 end
	 o.old_pkgs[pkgname] = true
	 p.abi = abi
	 p.is_automatic = automatic == "1"
	 p.is_locked = locked == "1"
	 p.is_installed = true
	 p.origin = o
	 p.num_depending = 0
	 p.dep_pkgs = {}
	 pkg_count = pkg_count + 1
      end
      Msg.cont (1, "The list of installed packages has been loaded (" .. pkg_count .. " packages)")
      PACKAGES_CACHE_LOADED = true
   end
end

-- add reverse dependency information (who depends on me?)
DEP_PKGS_CACHE_LOADED = false

local function dep_pkgs_cache_load ()
   if not DEP_PKGS_CACHE_LOADED then
      packages_cache_load ()
      Msg.cont (1, "Load package dependencies")
      local p = {}
      local lines = PkgDb.query {table = true, "%n-%v %rn-%rv"}
      for i, line in ipairs (lines) do
	 local pkgname, dep_pkg = string.match (line, "(%S+) (%S+)")
	 if pkgname ~= rawget (p, "name") then
	    p = Package:new (pkgname) -- fetch cached package record
	    p.dep_pkgs = {}
	 end
	 p.num_depending = p.num_depending + 1
	 table.insert (p.dep_pkgs, dep_pkg)
      end
      Msg.cont (1, "Package dependencies have been loaded")
      DEP_PKGS_CACHE_LOADED = true
   end
end

--
SHARED_LIBS_CACHE_LOADED = false

local function shared_libs_cache_load ()
   if not SHARED_LIBS_CACHE_LOADED then
      packages_cache_load ()
      Msg.cont (1, "Load list of required shared libraries")
      local p = {}
      local lines = PkgDb.query {table = true, "%n-%v %B"}
      for i, line in ipairs (lines) do
	 local pkgname, lib = string.match (line, "^(%S+) (%S+%.so.%d+)$")
	 if pkgname then
	    if pkgname ~= rawget (p, "name") then
	       p = Package:new (pkgname) -- fetch cached package record
	       p.shared_libs = {}
	    end
	    table.insert (p.shared_libs, lib)
	 end
      end
      Msg.cont (1, "The list of required shared libraries has been loaded")
      SHARED_LIBS_CACHE_LOADED = true
   end
end

-- 
local function get (name)
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
local function get_attribute (self, k)
   for i, v in ipairs (PkgDb.query {table = true, "%At %Av", self.name}) do
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

local function __index (self, k)
   local function __pkg_vars (self, k)
      local function set_field (field, v)
	 if v == "" then v = false end
	 self[field] = v
      end
      local t = PkgDb.query {table = true, "%q\n%k\n%a\n%#r", self.name_base}
      set_field ("abi", t[1])
      set_field ("is_locked", t[2] == "1")
      set_field ("is_automatic", t[3] == "1")
      set_field ("num_depending", tonumber (t[4]))
      return self[k]
   end
   function load_num_dependencies (self, k)
      local t = PkgDb.query {table = true, "%#d %n-%v"}
      for i, line in ipairs (t) do
	 local num_dependencies, pkgname = string.match (line, "(%d+) (%S+)")
	 PACKAGES_CACHE[pkgname].num_dependencies = tonumber (num_dependencies)
      end
      return self[k]
   end

   local dispatch = {
      abi = __pkg_vars,
      is_automatic = __pkg_vars,
      is_locked = __pkg_vars,
      num_depending = __pkg_vars,
      num_dependencies = load_num_dependencies,
      flavor = get_attribute,
      FreeBSD_version = get_attribute,
      name_base = pkg_basename,
      name_base_major = pkg_strip_minor,
      version = pkg_version,
      dep_pkgs = dep_pkgs_cache_load,
      shared_libs = shared_libs_cache_load,
      is_installed = function (self, k)
	 return false -- always explicitly set when found or during installation
      end,
      categories = function (self, k)
	 return PkgDb.query {table = true, "%C", self.name}
      end,
      files = function (self, k)
	 return PkgDb.query {table = true, "%Fp", self.name}
      end,
      shlibs = function (self, k)
	 return PkgDb.query {table = true, "%B", self.name}
      end,
      pkg_filename = function (self, k)
	 return pkg_filename {subdir = "All", self}
      end,
      bak_filename = function (self, k)
	 return pkg_filename {subdir = "portmaster-backup", extension = Options.backup_format, self}
      end,
      origin = function (self, k)
	 TRACE ("Looking up origin for", self.name)
	 local port = PkgDb.query {"%o", self.name}
	 if port then
	    local flavor = self.flavor
	    local n = flavor and port .. "@" .. flavor or port
	    return Origin:new (n)
	 end
      end,
   }
   
   TRACE ("INDEX(p)", self, k)
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
	 error ("illegal field requested: Package." .. k)
      end
      TRACE ("INDEX(p)->", self, k, w)
   else
      TRACE ("INDEX(p)->", self, k, w, "(cached)")
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
   automatic_get = automatic_get,
   automatic_check = automatic_check,
   packages_cache_load = packages_cache_load,
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
