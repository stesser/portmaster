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
-- return port name without flavor
local function port (origin)
   return (string.match (origin.name, "^[^:@]+"))
end

-- return full path to the port directory
local function path (origin)
   return PORTSDIR .. port (origin)
end

-- check whether port directory for given origin exists
local function check_path (origin)
   return is_dir (path (origin))
end

-- return flavor of passed origin or nil
local function flavor (origin)
   return (string.match (origin.name, "%S+@([^:]+)"))
end

-- return path to the portdb directory (contains cached port options)
local function portdb_path (origin)
   local dir = port (origin)
   return PORT_DBDIR .. dir:gsub ("/", "_")
end

-- call make for origin with arguments used e.g. for variable queries (no state change)
local function port_make (origin, args)
   local flavor = flavor (origin)
   if flavor then
      table.insert (args, 1, "FLAVOR=" .. flavor)
   end
   local dir = path (origin)
   if args.jailed and JAILBASE then
      dir = JAILBASE .. dir
      args.jailed = false
   end
   if not is_dir (dir) then
      return nil, "port directory " .. dir .. " does not exist"
   end
   if Options.make_args then
      for i, v in ipairs (Options.make_args) do
	 table.insert (args, i, v)
      end
   end
   table.insert (args, 1, "-C")
   table.insert (args, 2, dir)
   return Exec.run (MAKE_CMD, args)
end

-- return the Makefile variable named "$var" for port "$origin" (with optional flavor)
local function port_var (origin, args)
   for i = #args, 1, -1 do
      table.insert (args, i, "-V")
   end
   args.safe = true
   if args.trace then
      local dbginfo = debug.getinfo (2, "ln")
      table.insert (args, "LOC=" .. dbginfo.name .. ":" .. dbginfo.currentline)
   end
   local result = port_make (origin, args)
   if result then
      if args.split then
	 result = split_words (result)
      end
      if result == "" then
	 result = nil
      end
   end
   return result
end

-- check whether port is marked BROKEN, IGNORE, or FORBIDDEN
local function check_forbidden (origin)
   local dir = port (origin)

   --TRACE ("grep", "-E", "-ql", "'^(BROKEN|FORBIDDEN|IGNORE)'", port_dir (origin) .. "/Makefile")
   local makefile = io.open (origin:path () .. "/Makefile", "r")
   local ignore_type
   for line in makefile:lines () do
      if line:match ("^(BROKEN|FORBIDDEN|IGNORE)") then
	 local reason = origin:port_var {table = true, "BROKEN", "FORBIDDEN", "IGNORE"}
	 for i, ignore_type in ipairs ({"BROKEN", "FORBIDDEN", "IGNORE"}) do
	    if reason[i] then
	       Msg.cont (1, "This port is marked", ignore_type)
	       Msg.cont (1, reason[i])
	       return true
	    end
	 end
      end
   end
   return false
end

-- local function only to be called when the flavor is queried via __index !!!
local function port_flavor_get (origin)
   local f = flavor (origin)
   if f then
      return f -- return flavor passed in as part of the origin
   end
   --[[
   local flavors = origin.flavors
   if flavors then
      f = flavors[1]
      origin.name = origin.name .. "@" .. f -- adjust origin by appending default flavor to name
   end
   return f
   --]]
end

-- try to find matching port origin (directory and optional flavor) given a passed in new origin and current package name
local function origin_from_dir_and_pkg (origin)
   -- determine package name for given origin
   local pkg_new = origin.pkg_new
   if pkg_new then
      local old_pkg = origin.old_pkg
      -- compare package names including major version numbers
      -- <se> TEST IST NOT CORRECT, E.G. for markdown-mode.el-emacs25-2.3_4 ==> markdown-mode
      local pkgname_major = old_pkg.base_name_major
      if pkgname_major == pkg_new.base_name_major then
	 return origin
      end
      -- try available flavors in search for a matching package name with same major version
      local dir = origin.port
      local flavors = origin.flavors
      if flavors then
	 for i, flavor in ipairs (flavors) do
	    local origin = Origin:new (dir .. "@" .. flavor)
	    local pkg_new = origin.pkg_new
	    -- compare package names including major version numbers
	    if pkgname_major == pkg_new.base_name_major then
	       return origin
	    end
	    origin.pkg_new = nil
	 end
	 -- try available flavors in search for a matching package name ignoring the version number (in case major version has been incremented)
	 local pkgname_base = old_pkg.name_base
	 if pkgname_base == pkg_new.name_base then
	    return PkgDb.query {"%o", old_pkg} -- is this correct ???
	 end
	 -- <se> is this additional search loop required? Better to fail if no packages with same major version?
	 local flavor = origin.flavor
	 if flavor then
	    table.insert (flavors, 1, flavor)
	 end
	 for i, flavor in ipairs (flavors) do
	    local origin = Origin:new (dir .. "@" .. flavor)
	    local pkg_new = origin.pkg_new
	    -- compare package names with version numbers stripped off
	    if pkgname_base == pkg_new.strip_version then
	       return origin
	    end
	    origin.pkg_new = nil
	 end
	 -- 
	 return Origin:new (origin_old:port_var {"PKGORIGIN"})
      end
   end
   origin.pkg_new = nil
end

-- set variable origin_new in external frame to new origin@flavor (if any) for given old origin@flavor (or to the old origin as default)
local function origin_new_from_old (origin_old, pkgname_old)
   assert (pkgname_old, "Need pkgname_old for origin " .. origin_old.name)
   -- just check whether old origin builds package with same name and major version number
   local origin_new = origin_from_dir_and_pkg (origin_old, pkgname_old)
   if not origin_new then
      origin_new, reason = origin_find_moved (origin_old)
      -- return passed in origin if no entry in MOVED applied
      if origin_new.name ~= origin_old.name then
	 if not reason then
	    Msg.cont (0, "The origin of", pkgname_old.name, "in the ports system cannot be found.")
	 else
	    -- empty origin_new means that the port has been removed
	    local text = "removed"
	    if origin_new.name then
	       text = "moved to " .. origin_new.name
	    end
	    Msg.cont (1, "The", origin_old.name, "port has been", text)
	    Msg.cont (1, "Reason:", reason)
	 end
      end
   end
   return origin_new
end

-- return origin corresponding to given relative or absolute directory
local function origin_from_dir (dir_glob)
   local result = {}
   for i, dir in shell_pipe ("/bin/sh", "-c", "cd", PORTSDIR, ";", "echo", dir_glob) do
      local origin = Origin:new (dir:gsub(".*/([^/]+/([^/]+)$", "%1"))
      local name = origin:port_var {"PKGORIGIN"}
      if name then
	 result:insert (origin)
      end
   end
   return result
end

-- return all origin@flavor for port(s) in relative or absolute directory "$dir" (<se> TOO EXPENSIVE!!!)
local function origin_old_from_port (port_glob)
   local dir_glob = port (port_glob)
   local flavors = flavor (port_glob)
   local origins = origin_from_dir (dir_glob)
   local result = {}
   for i, origin in ipairs (origins) do
      if flavors ~= "" then
	 for i, flavor in ipairs (flavors) do
	    table.insert (result, Origin:new (origin .. "@" .. flavor))
	 end
      else
	 table.insert (result, Origin:new (origin))
      end
   end
   return result
end

--## return old pkgname for given new origin@flavor
--# function pkgnames_old_from_moved_to_origin ()
--#	local origin="$1"
--#	local line matched
--#
--#	TRACE grep "^[^|]*|${origin}|" "$PORTSDIR/MOVED"
--#	matched=""
--#	for line in "$(${GREP_CMD} "^[^|]*|${origin}|" "$PORTSDIR/MOVED")"; do
--#                PkgDb.query "%n-%v" "${line%%|*}" && matched=yes
--#	done
--#	test "$matched" = yes
--#}

-- optionally or forcefully configure port
local function configure (origin, force)
   local target = force and "config" or "config-conditional"
   return origin:port_make {to_tty = true, as_root = true, "-D", "NO_DEPENDS", "-D", "DISABLE_CONFLICTS", target}
end

-- check config options and ask for confirmation if interactive
local function check_options (origin)
   if not Options.no_make_config then
      if not origin:configure (Options.force_config) then
	 return false
      end -- fail "Port configuration failed" -- ??? retries are disconnected ???
      cause = check_forbidden (origin)
      if cause and origin:port_var {"OPTIONS"} then
	 Msg.cont (0, "You may try to change the port options to allow this port to build")
	 Msg.cont (0)
	 read_nl ("Press the [Enter] or [Return] key to continue ")
	 origin:configure (true)
	 cause = check_forbidden (origin)
      end
      if cause then
	 Msg.cont (0, "If you are sure you can build this port, remove the", cause, "line in the Makefile and try again.")
	 return false
      end
      -- ask for confirmation if requested by a program option
      if Options.interactive then
	 if not read_yn ("Perform upgrade", "y") then
	    Msg.cont (0, "Action will be skipped on user request")
	    return true
	 end
      end
      -- warn if port is interactive
      if origin:port_var {"IS_INTERACTIVE"} then
	 Msg.cont (0, "Warning:", origin.name, "is interactive, and will likely require attention during the build")
	 read_nl ("Press the [Enter] or [Return] key to continue ")
      end
   end
   return true
end

-- return false if special license required and denied
local function check_license (origin)
   if origin:port_var {"LICENSE"} then
      if origin:port_make {to_tty = true, as_root = true, "-D", "DEFER_CONFLICTS_CHECK", "-D", "DISABLE_CONFLICTS", "extract", "ask-license"} then
	 -- NYI - fix condition !!!
	 return true
      else
	 port_clean (origin)
	 return false
      end
   end
end

-- # wait for a line stating success or failure fetching all distfiles for some port origin and return status
local function wait_checksum (origin)
   local dir = port (origin)
   if Options.dry_run then
      return true
   end
   local errmsg = "cannot find fetch acknowledgement file"
   if TMPFILE_FETCH_ACK then
      local status = shell (GREP_CMD, {safe = true, "-m", "1", "OK " .. dir .. " ", TMPFILE_FETCH_ACK})
      print ("'" .. status .. "'")
      if not status then
	 sleep (1)
	 repeat
	    Msg.cont (0, "Waiting for download of all distfiles for", dir, "to complete")
	    status = shell (GREP_CMD, {safe = true, "-m", "1", "OK " .. dir .. " ", TMPFILE_FETCH_ACK})
	    if not status then
	       sleep (3)
	    end
	 until status
      end
      errmsg = string.match (status, "NOTOK " .. dir .. "(.*)")
      if not errmsg then
	 return true
      end
   end
   return false, "Download of distfiles for " .. origin.name .. " failed: " .. errmsg
end

-- check wether port is on the excludes list
local function check_excluded (origin)
   return Excludes.check_port (origin.name)
end

-- return corresponding package object
local function pkg (origin, jailed)
   local p = origin.pkg_var
   if p == nil then
      p = Package:new (origin:port_var {trace = true, jailed = jailed, "PKGNAME"}) or false
      origin.pkg_var = p
   end
   return p
end

-- return corresponding package object
local function curr_pkg (origin)
   local p = origin.curr_pkg_var
   if p == nil then
      p = Package:new (PkgDb.pkgname_from_origin (origin)) or false
      origin.curr_pkg_var = p
   end
   return p
end

-- -------------------------
local MOVED_CACHE = nil -- table indexed by old origin (as text) and giving struct with new origin (as text), date and reason for move
local MOVED_CACHE_REV = nil -- table indexed by new origin (as text) giving previous origin (as text)

--
--[[
Cases:
   1) no flavor -> no flavor (non-flavored port)
   2) no flavor -> with flavor (flavors added)
   3) with flavor -> no flavor (flavors removed)
   4) no flavor -> no flavor (flavored port !!!)

Cases 1, 2 and 3 can easily be dealt with by comparing the 
full origin with column 1 (table lookup using full origin).

Case 4 cannot be assumed from the origin having or not having 
a flavor - and it looks identical to case 1 in the MOVED file.

If the passed in origin contains a flavor, then entries before
the addition of flavors should be ignored, but there is no way
to reliably get the date when flavors were added from the MOVED 
file.
--]]

local function moved_cache_load (filename)
   local function register_moved (old, new, date, reason)
      if old then
	 local o_p, o_f = string.match (old, "([^@]+)@?([%S]*)")
	 local n_p, n_f = string.match (new, "([^@]+)@?([%S]*)")
	 o_f = o_f ~= "" and o_f or nil
	 n_f = n_f ~= "" and n_f or nil
	 if not MOVED_CACHE[o_p] then
	    MOVED_CACHE[o_p] = {}
	 end
	 table.insert (MOVED_CACHE[o_p], {o_p, o_f, n_p, n_f, date, reason})
      end
   end

   if not MOVED_CACHE then
      Msg.cont (1, "Load list of renamed of removed ports")
      local movedfile = io.open (filename, "r")
      MOVED_CACHE = {}
      if movedfile then
	 for line in movedfile:lines () do
	    register_moved (string.match (line, "^([^#][^|]+)|([^|]*)|([^|]+)|([^|]+)"))
	 end
	 io.close (movedfile)
      end
      Msg.cont (1, "The list of renamed of removed ports has been loaded")
   end
end

-- try to find origin in list of moved or deleted ports, returns new origin or nil if found, false if not found, followed by reason text
local function lookup_moved_origin (origin)
   local function o (p, f)
      if p and f then
	 p = p .. "@" .. f
      end
      return p
   end
   local function locate_move (p, f, min_i)
      local m = MOVED_CACHE[p]
      if not m then
	 return p, f, nil
      end
      local max_i = #m
      local i = max_i
      TRACE ("MOVED?", o (p, f), p, f)
      repeat
	 local o_p, o_f, n_p, n_f, date, reason = table.unpack (m[i])
	 if p == o_p and (not f or not o_f or f == o_f) then
	    local p = n_p
	    local f = f ~= o_f and f or n_f
	    local r = reason .. " on " .. date
	    TRACE ("MOVED->", o (p, f), r)
	    if not p or access (PORTSDIR .. p .. "/Makefile") then
	       return p, f, r
	    end
	    return locate_move (p, f, i + 1)
	 end
	 i = i - 1
      until i < min_i
      return p, f, nil
   end

   if not MOVED_CACHE then
      moved_cache_load (PORTSDIR .. "MOVED") -- use specific configuration parameter ???
   end
   local p, f, r = locate_move (origin.port, origin.flavor, 1)
   if p and r then
      origin = Origin:new (o (p, f))
      origin.reason = r
      return origin
   end
end

-- return list of previous origins as table of strings (not objects!)
local function list_prev_origins (origin)
   return {} -- DUMMY / NYI
end

-- list dependencies for given origin and phase (build, run, test, all)
local DEPEND_ARGS = {
   build = "-V PKG_DEPENDS -V EXTRACT_DEPENDS -V PATCH_DEPENDS -V FETCH_DEPENDS -V BUILD_DEPENDS -V LIB_DEPENDS",
   run = "-V RUN_DEPENDS -V LIB_DEPENDS",
   test = "-V TEST_DEPENDS",
   -- package = "",
}
DEPEND_ARGS.all = DEPEND_ARGS.build .. " -V RUN_DEPENDS"

local function depends (origin, dep_type) -- Check whether these function can return "special depends" with make target attached to the origin !!! ToDo ???
   TRACE ("CHECK_DEPENDS", origin.name, dep_type .. "-depends-list")
   local args = DEPEND_ARGS[dep_type]
   assert (args, "No dependency check defined for phase '" .. dep_type .. "'")
   local lines = origin:port_make {table = true, safe = true, "-DDEPENDS_SHOW_FLAVOR", dep_type .. "-depends-list"}
   local result = {}
   for i, line in ipairs (lines) do
      table.insert (result, line:match (".*/([^/]+/[^/]+)$"))
   end
   TRACE ("CHECK_DEPENDS->", origin.name, table.unpack (result))
   return result
end

-- check conflicts of new port with installed packages (empty table if no conflicts found)
local function check_conflicts (origin)
   local list = {}
   local conflicts = origin:port_make {table = true, safe = true, "check-conflicts"}
   for i, line in ipairs (conflicts) do
      local pkgname = line:match ("^%s+(%S+)%s*")
      if pkgname then
	 table.insert (list, pkgname)
      elseif #list > 0 then
	 break
      end
   end
   return list
end

-- ----------------------------------------------------------------------------------
-- create new Origins object or return existing one for given name
-- the Origin class describes a port with optional flavor
local ORIGINS_CACHE = {}
--setmetatable (ORIGINS_CACHE, {__mode = "v"})

local function __index (self, k)
   local function __port_vars (self, k)
      local port = Port:new (self.port)
      local v = rawget (port, k)
      TRACE ("RAW_GET(" .. port.name .. ", " .. k ..")", v ~= nil and v or "<NIL>")
      if v ~= nil then
	 return v
      end
      local t = port_var (self, {table = true,
				 "DISTINFO_FILE",
				 "BROKEN",
				 "FORBIDDEN",
				 "IGNORE",
				 "IS_INTERACTIVE",
				 "LICENSE",
				 "FLAVORS",
				 "ALL_OPTIONS",
				 "NEW_OPTIONS",
				 "PORT_OPTIONS",
				 "CATEGORIES",
				 "PKGNAME",
      }) or {}
      TRACE ("PORT_VAR(" .. self.name .. ", " .. k ..")", table.unpack (t))
      set_str (port, "distinfo_file", t[1])
      set_bool (port, "is_broken", t[2])
      set_bool (port, "is_forbidden", t[3])
      set_bool (port, "is_ignore", t[4])
      set_bool (port, "is_interactive", t[5])
      set_table (port, "license", t[6])
      set_table (port, "flavors", t[7])
      set_table (port, "all_options", t[8])
      set_table (port, "new_options", t[9])
      set_table (port, "port_options", t[10])
      set_table (port, "categories", t[11])
      local pkgname = t[12]
      if pkgname then
	 self.pkg_new = Package:new (pkgname)
	 TRACE ("PKG_NEW", self.name, pkgname)
      end
      return rawget (port, k) or rawget (self, k)
   end
   local function __port_depends (self, k)
      local d = string.match (k, "[^_]+")
      TRACE ("DEPENDS", k, d)
      return depends (self, d)
   end
   local function __check_port_exists (self, k)
      --return access (PORTSDIR .. self.port .. "/Makefile", "r")
      --TRACE ("ACESS CHECK FOR PATH:", self.path)
      local result = access (self.path .. "/Makefile", "r")
      --TRACE ("RESULT:", result)
      return result
   end

   local dispatch = {
      distinfo_file = __port_vars,
      is_broken = __port_vars,
      is_forbidden = __port_vars,
      is_ignore = __port_vars,
      is_interactive = __port_vars,
      license = __port_vars,
      flavors = __port_vars,
      flavor = port_flavor_get,
      all_options = __port_vars,
      new_options = __port_vars,
      port_options = __port_vars,
      categories = __port_vars,
      pkg_new = __port_vars,
      path = path,
      port = port,
      port_exists = __check_port_exists,
      fetch_depends = __port_depends,
      extract_depends = __port_depends,
      patch_depends = __port_depends,
      build_depends = __port_depends,
      run_depends = __port_depends,
      pkg_depends = __port_depends,
      conflicts = function (self, k)
	 return check_conflicts (self)
      end,
      old_pkgs = PkgDb.pkgname_from_origin,
   }
   
   TRACE ("INDEX(o)", self, k)
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
	 error ("illegal field requested: Origin." .. k)
      end
      TRACE ("INDEX(o)->", self, k, w)
   else
      TRACE ("INDEX(o)->", self, k, w, "(cached)")
   end
   return w
end

--[[

--]]

local function new (origin, name)
   --local TRACE = print -- TESTING
   if name then
      local O = ORIGINS_CACHE[name]
      if not O then
	 O = {name = name}
	 O.__class = origin
	 origin.__index = __index
	 origin.__tostring = function (origin)
	    return origin.name
	 end
	 --origin.__eq = function (a, b) return a.name == b.name end
	 setmetatable (O, origin)
	 TRACE ("NEW Origin", name)
	 ORIGINS_CACHE[name] = O
      else
	 TRACE ("NEW Origin", name, "(cached)")
      end
      return O
   end
   return nil
end

-- 
return {
   --name = false,
   new = new,
   check_excluded = check_excluded,
   check_options = check_options,
   check_path = check_path,
   configure = configure,
   depends = depends,
   -- ...
   port_make = port_make,
   port_var = port_var,
   portdb_path = portdb_path,
   wait_checksum = wait_checksum,
   moved_cache_load = moved_cache_load,
   lookup_moved_origin = lookup_moved_origin,
   list_prev_origins = list_prev_origins,
}

--[[
   Instance variables of class Origin:
   - pkg_new = package object (to be installed from this origin)
   - categories = table of categories
   - conflicts = table of package objects for conflicting packages
   - distinfo_file = full path name of distinfo file of this port
   - is_broken = Makefile is marked BROKEN
   - is_forbidden = Makefile is marked FORBIDDEN
   - is_ignore = Makefile is marked IGNORE
   - is_interactive = Makefile is marked IGNORE
   - path = pathname of port corresponding to origin
   - port = sub-directory of port in ports tree
   - flavor = flavor part of given origin with flavor
   - flavors = table of supported flavors for this port
   - all_options = all available options of this port
   - port_optiomns = currently selected options of this port
   - fetch_depends = table of origin names required for make fetch
   - extract_depends = table of origin names required for make extract
   - patch_depends = table of origin names required for make patch
   - build_depends = table of origin names required for make depends
   - run_depends = table of origin names required to execute the products of this port
   - pkg_depends = table of origin names required for make package
--]]

--[[
   PROBLEM: different packages can be built from the same port (without flavor)
   EXAMPLE: devel/lua-posix will create different packages depending on the default LUA version
--]]
