--[[
oSPDX-License-Identifier: BSD-2-Clause-FreeBSD

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
   return (string.match (origin.name, "^[^:@%%]+"))
end

-- return full path to the port directory
local function path (origin)
   return PORTSDIR .. port (origin)
end

--
local function check_port_exists (origin)
   return access (path (origin) .. "/Makefile", "r")
end

-- return flavor of passed origin or nil
local function flavor (origin)
   return (string.match (origin.name, "%S+@([^:%%]+)"))
end

--
-- return flavor of passed origin or nil
local function pseudo_flavor (origin)
   return (string.match (origin.name, "%S+%%([^:%%]+)"))
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
   local pf = pseudo_flavor (origin)
   if pf then
      table.insert (args, 1, "DEFAULT_VERSIONS='" .. pf .. "'")
      TRACE ("DEFAULT_VERSIONS", pf)
   end
   local result = Exec.run (MAKE_CMD, args)
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
   return port_make (origin, args)
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

-- check config options and ask for confirmation if interactive, return true if options changed
local function check_options (origin)
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

--
local function checksum (origin)
   Distfile.fetch (origin.name)
end

-- # wait for a line stating success or failure fetching all distfiles for some port origin and return status
local function wait_checksum (origin)
   if Options.dry_run then
      return true
   end
   local errmsg = "cannot find fetch acknowledgement file"
   local dir = origin.port
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

--[[
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
--]]

-- install newly built port
local function install (origin)
   return origin:port_make {to_tty = true, jailed = true, as_root = true, "install"}
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
	 if n_p then
	    if not MOVED_CACHE_REV[n_p] then
	       MOVED_CACHE_REV[n_p] = {}
	    end
	    table.insert (MOVED_CACHE_REV[n_p], {o_p, o_f, n_p, n_f, date, reason})
	 end
      end
   end

   if not MOVED_CACHE then
      MOVED_CACHE = {}
      MOVED_CACHE_REV = {}
      local filename = PORTSDIR .. "MOVED" -- allow override with configuration parameter ???
      Msg.start (2, "Load list of renamed or removed ports from " .. filename)
      local movedfile = io.open (filename, "r")
      if movedfile then
	 for line in movedfile:lines () do
	    register_moved (string.match (line, "^([^#][^|]+)|([^|]*)|([^|]+)|([^|]+)"))
	 end
	 io.close (movedfile)
      end
      Msg.cont (2, "The list of renamed of removed ports has been loaded")
      Msg.start (2)
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
	    if not p or access (PORTSDIR .. p .. "/Makefile", "r") then
	       return p, f, r
	    end
	    return locate_move (p, f, i + 1)
	 end
	 i = i - 1
      until i < min_i
      return p, f, nil
   end

   if not MOVED_CACHE then
      moved_cache_load ()
   end
   local p, f, r = locate_move (origin.port, origin.flavor, 1)
   if r then
      if p then
	 origin = Origin:new (o (p, f))
      end
      origin.reason = r
      return origin
   end
end

-- try to find origin in list of moved or deleted ports, returns new origin or nil if found, false if not found, followed by reason text
local function lookup_prev_origins (origin)
   --[[
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

   if not MOVED_CACHE_REV then
      moved_cache_load ()
   end
   local p, f, r = locate_move (origin.port, origin.flavor, 1)
   if p and r then
      origin = Origin:new (o (p, f))
      origin.reason = r
      return origin
   end
   --]]
   return {} -- DUMMY RETURN VALUE
end

-- return list of previous origins as table of strings (not objects!)
local function list_prev_origins (origin)
   return {} -- DUMMY / NYI
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

--[=[
--
local function load_default_versions (origin)
   local vars = {
      --{ "apache", "^apache(%d)(%d)-", "apache=%d.%d" },
      --[[
      --bdb = { "db(%d+)-", "bdb=%d" },
      --corosync = {},
      --emacs = {},
      --firebird = {},
      --fortran = {},
      --fpc = {},
      --gcc = {},
      --ghostscript = {},
      --julia = {},
      --lazarus = {},
      --linux = {},
      { "llvm", "^llvm(%d+)-", "llvm=%d" },
      { "lua", "^lua(%d)(%d)-", "lua=%d.%d" },
      { "mysql", "^mysql(%d)(%d)-", "mysql=%d.%d" },
      --perl5 = {},
      { "pgsql", "^pgsql(1)(%d)-", "postgresql=%d%d" },
      { "pgsql", "^pgsql(9)(%d)-", "postgresql=%d.%d" },
      { "php", "^php(%d)(%d)-", "php=%d.%d" },
      { "python", "^py(%d)(%d)-", "python=%d.%d" },
      { "python2", "^py(2)(%d)-", "python2=%d.%d" },
      { "python3", "^py(3)(%d)-", "python3=%d.%d" },
      { "ruby", "^ruby(%d)(%d)-", "ruby=%d.%d" },
      --rust = {},
      { "samba", "^samba(%d)(%d+)", "samba=%d.%d" },
      --ssl = {},
      { "tcltk", "^t[ck]l?(%d)(%d)-", "tcltk=%d.%d" },
      --varnish = {},
      --]]
      "apache",
      "llvm",
      "lua",
      "mysql",
      "pgsql",
      "php",
      "python",
      "python2",
      "python3",
      "ruby",
      "samba",
      "tcltk",
   }
   local default_versions = {}
   local make_args = {}
   for i, make_var in ipairs (vars) do
      make_args[i] = "DEFAULT_" .. string.upper (make_var)
   end
   local T = origin:port_var {table = true, make_args}
   for i, make_var in ipairs (vars) do
      DEFAULT_VERSIONS[make_var] = T[i]
   end
end
--]=]

--
local function check_config_allow (origin, recursive)
   TRACE ("CHECK_CONFIG_ALLOW", origin.name, recursive)
   function check_ignore (name, field)
      TRACE ("CHECK_IGNORE", origin.name, name, field, rawget (origin, field))
      if rawget (origin, field) then
	 Msg.cont (0, origin.name, "will be skipped since it is marked", name .. ":", origin[field])
	 Msg.cont (0, "If you are sure you can build this port, remove the", name, "line in the Makefile and try again")
	 if not Options.no_confirm then
            read_nl ("Press the [Enter] or [Return] key to continue ")
	 end
	 origin.skip = true
      end
   end
   check_ignore ("BROKEN", "is_broken")
   check_ignore ("IGNORE", "is_ignore")
   if Options.no_make_config then
      check_ignore ("FORBIDDEN", "is_forbidden")
   end
   if rawget (origin, "skip") then
      return false
   elseif not recursive then
      local do_config
      if origin.is_forbidden then
	 Msg.cont (0, origin.name, "is marked FORBIDDEN:", origin.is_forbidden)
	 if origin.all_options then
	    Msg.cont (0, "You may try to change the port options to allow this port to build")
	    Msg.cont (0)
	    if read_yn ("Do you want to try again with changed port options") then
	       do_config = true
	    end
	 end
      elseif origin.new_options or Options.force_config then
	 do_config = true
      end
      if do_config then
	 TRACE ("NEW_OPTIONS", origin.new_options)
	 origin:configure (true)
	 return false
      end
   end
   -- ask for confirmation if requested by a program option
   if Options.interactive then
      if not read_yn ("Perform upgrade", "y") then
	 Msg.cont (0, "Action will be skipped on user request")
	 origin.skip = true
	 return false
      end
   end
   -- warn if port is interactive
   if origin.is_interactive then
      Msg.cont (0, "Warning:", origin.name, "is interactive, and will likely require attention during the build")
      if not Options.no_confirm then
	 read_nl ("Press the [Enter] or [Return] key to continue ")
      end
   end
end

-- ----------------------------------------------------------------------------------
-- create new Origins object or return existing one for given name
-- the Origin class describes a port with optional flavor
local ORIGINS_CACHE = {}
--setmetatable (ORIGINS_CACHE, {__mode = "v"})

local function __newindex (origin, n, v)
   TRACE ("SET(o)", origin.name, n, v)
   rawset (origin, n, v)
end

--[[
local function origin_alias (origin)
   local default_flavor = origin.flavors and origin.flavors[1]
   TRACE ("ORIGIN_ALIAS", origin.name, default_flavor)
   if default_flavor then
      local flavor = origin.flavor
      if flavor then
	 if default_flavor == flavor then
	    return origin.port
	 end
      else
	 -- add missing default flavor to port name
	 origin.name = origin.name .. "@" .. default_flavor
	 TRACE ("ORIGINS_CACHE_ALIAS", origin.name)
	 return origin.name
      end
   end
end
--]]

--
ORIGIN_ALIAS = {}

local function __index (origin, k)
   local function __port_vars (origin, k, recursive)
      local function check_origin_alias () -- origin is UPVALUE
	 local function adjustname (new_name) -- origin is UPVALUE
	    TRACE ("ORIGIN_SETALIAS", origin.name, new_name)
	    ORIGIN_ALIAS[origin.name] = new_name
	    local o = Origin.get (name)
	    if o then -- origin with alias has already been seen, move fields over and continue with new table
	       o.flavors = rawget (origin, "flavors")
	       o.pkg_new = rawget (origin, "pkg_new")
	       origin = o
	    end
	    ORIGINS_CACHE[origin.name] = false -- poison old value to cause error if accessed
	    origin.name = new_name
	    ORIGINS_CACHE[new_name] = origin
	 end
	 -- add missing default flavor, if applicable
	 local default_flavor = origin.flavors and origin.flavors[1]
	 local name = origin.name
	 if default_flavor and not string.match (name, "@") then -- flavor and default_version do not mix !!! check required ???
	    adjustname (name .. "@" .. default_flavor)
	 end
	 -- check for existing package cache entry and its origin
	 local p = Package.get (origin.pkg_new)
	 local o = p and p.origin -- MERGE !!!
	 TRACE ("CHECK_ORIGIN_ALIAS", origin and origin.name or "<nil>", o and o.name or "<nil>", p and p.name or "<nil>")
	 if o and o.name ~= origin.name then
	    adjustname (o.name)
	 end
      end
      local function set_pkgname (origin, var, pkgname)
	 if pkgname then
	    local p = Package:new (pkgname)
	    TRACE ("PKG_NEW", pkgname, origin.name, p.origin and p.origin.name or "''")
	    origin[var] = p
	 end
      end
      local t = origin:port_var {
	 table = true,
	 "PKGNAME",		--  1
	 "FLAVOR",		--  2
	 "FLAVORS",		--  3
	 "DISTINFO_FILE",	--  4
	 "BROKEN",		--  5
	 "FORBIDDEN",		--  6
	 "IGNORE",		--  7
	 "IS_INTERACTIVE",	--  8
	 "LICENSE",		--  9
	 "ALL_OPTIONS",		-- 10
	 "NEW_OPTIONS",		-- 11
	 "PORT_OPTIONS",	-- 12
	 "CATEGORIES",		-- 13
	 "FETCH_DEPENDS",	-- 14
	 "EXTRACT_DEPENDS",	-- 15
	 "PATCH_DEPENDS",	-- 16
	 "BUILD_DEPENDS",	-- 17
	 "LIB_DEPENDS",		-- 18
	 "RUN_DEPENDS",		-- 19
	 "TEST_DEPENDS",	-- 20
	 "PKG_DEPENDS",		-- 21
	 "CONFLICTS_BUILD",	-- 22
	 "CONFLICTS_INSTALL",	-- 23
	 "CONFLICTS",		-- 24
      } or {}
      TRACE ("PORT_VAR(" .. origin.name .. ", " .. k ..")", table.unpack (t))
      -- first check for and update port options since they might affect the package name
      set_table (origin, "new_options", t[11])
      set_str (origin, "is_broken", t[5])
      set_str (origin, "is_forbidden", t[6])
      set_str (origin, "is_ignore", t[7])
      set_pkgname (origin, "pkg_new", t[1])
      set_str (origin, "flavor", t[2])
      set_table (origin, "flavors", t[3])
      check_origin_alias () ---- SEARCH FOR AND MERGE WITH POTENTIAL ALIAS
      set_str (origin, "distinfo_file", t[4])
      set_bool (origin, "is_interactive", t[8])
      set_table (origin, "license", t[9])
      set_table (origin, "all_options", t[10])
      set_table (origin, "port_options", t[12])
      set_table (origin, "categories", t[13])
      set_table (origin, "fetch_depends_var", t[14])
      set_table (origin, "extract_depends_var", t[15])
      set_table (origin, "patch_depends_var", t[16])
      set_table (origin, "build_depends_var", t[17])
      set_table (origin, "lib_depends_var", t[18])
      set_table (origin, "run_depends_var", t[19])
      set_table (origin, "test_depends_var", t[20])
      set_table (origin, "pkg_depends_var", t[21])
      set_table (origin, "conflicts_build_var", t[22])
      set_table (origin, "conflicts_install_var", t[23])
      set_table (origin, "conflicts_var", t[24])
      return rawget (origin, k)
   end
   local function __port_depends (origin, k)
      local depends_table = {
	 build_depends = {
	    "extract_depends_var",
	    "patch_depends_var",
	    "fetch_depends_var",
	    "build_depends_var",
	    "lib_depends_var",
	    "pkg_depends_var",
	 },
	 run_depends = {
	    "lib_depends_var",
	    "run_depends_var",
	 },
	 test_depends = {
	    "test_depends_var",
	 },
	 special_depends = {
	    "build_depends_var",
	 },
      }
      local t = depends_table[k]
      assert (t, "non-existing dependency " .. k or "<nil>" .. " requested")
      local ut = {}
      for i, v in ipairs (t) do
	 for j, d in ipairs (origin[v] or {}) do
	    local pattern = k == "special_depends" and "^[^:]+:[^:]+:(%S+)" or "^[^:]+:([^:]+)$"
	    local o = string.match (d, pattern)
	    if o then
	       ut[o] = true
	    end
	 end
      end
      return table.keys (ut)
   end
   local function __port_conflicts (origin, k)
      local conflicts_table = {
	 build_conflicts = {
	    "conflicts_build_var",
	    "conflicts_var",
	 },
	 install_conflicts = {
	    "conflicts_install_var",
	    "conflicts_var",
	 },
      }
      local t = conflicts_table[k]
      assert (t, "non-existing conflict type " .. k or "<nil>" .. " requested")
      local ut = {}
      for i, v in ipairs (t) do
	 local t = origin[v]
	 TRACE ("CHECK_C?", origin.name, k, v)
	 if t then
	    for j, d in ipairs (t) do
	       ut[d] = true
	    end
	 end
      end
      return table.keys (ut)
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
      pkg_old = Package.packages_cache_load,
      pkg_new = __port_vars,
      --old_pkgs = PkgDb.pkgname_from_origin,
      path = path,
      port = port,
      port_exists = check_port_exists,
      fetch_depends = __port_depends,
      extract_depends = __port_depends,
      patch_depends = __port_depends,
      build_depends = __port_depends,
      run_depends = __port_depends,
      pkg_depends = __port_depends,
      special_depends = __port_depends,
      fetch_depends_var = __port_vars,
      extract_depends_var = __port_vars,
      patch_depends_var = __port_vars,
      build_depends_var = __port_vars,
      lib_depends_var = __port_vars,
      run_depends_var = __port_vars,
      test_depends_var = __port_vars,
      conflicts_build_var = __port_vars,
      conflicts_install_var = __port_vars,
      conflicts_var = __port_vars,
      build_conflicts = __port_conflicts,
      install_conflicts = __port_conflicts,
   }
   
   TRACE ("INDEX(o)", origin, k)
   local w = rawget (origin.__class, k)
   if w == nil then
      rawset (origin, k, false)
      local f = dispatch[k]
      if f then
	 w = f (origin, k)
	 if w then
	    rawset (origin, k, w)
	 else
	    w = false
	 end
      else
	 error ("illegal field requested: Origin." .. k)
      end
      TRACE ("INDEX(o)->", origin, k, w)
   else
      TRACE ("INDEX(o)->", origin, k, w, "(cached)")
   end
   return w
end

--
local function get (name)
   if name then
      TRACE ("GET(o)", name)
      local result = rawget (ORIGINS_CACHE, name)
      if result == false then
	 return get (ORIGIN_ALIAS[name])
      end
      TRACE ("GET(o)->", name, tostring(result))
      return result
   end
end

--
local function new (origin, name)
   --local TRACE = print -- TESTING
   if name then
      local O = get (name)
      if not O then
	 O = {name = name}
	 O.__class = origin
	 origin.__index = __index
	 origin.__newindex = __newindex -- DEBUGGING ONLY
	 origin.__tostring = function (origin)
	    return origin.name
	 end
	 --origin.__eq = function (a, b) return a.name == b.name end
	 setmetatable (O, origin)
	 TRACE ("NEW Origin", name)
	 ORIGINS_CACHE[name] = O
      else
	 TRACE ("NEW Origin", name, "(cached)", O.name)
      end
      return O
   end
   return nil
end

--
local function delete (origin)
   ORIGINS_CACHE[origin.name] = nil
end

-- DEBUGGING: DUMP INSTANCES CACHE
local function dump_cache ()
   local t = ORIGINS_CACHE
   for i, v in ipairs (table.keys (t)) do
      if t[v] then
	 TRACE ("ORIGINS_CACHE", i, v, table.unpack (table.keys (t[v])))
      else
	 TRACE ("ORIGINS_CACHE", i, v, "ALIAS", ORIGIN_ALIAS[v])
      end
   end
   local t = ORIGIN_ALIAS
   for i, v in ipairs (table.keys (t)) do
      TRACE ("ORIGIN_ALIAS", i, v, t[v])
   end
end

-- 
return {
   --name = false,
   new = new,
   get = get,
   check_excluded = check_excluded,
   check_path = check_path,
   check_config_allow = check_config_allow,
   checksum = checksum,
   configure = configure,
   delete = delete,
   depends = depends,
   install = install,
   port_make = port_make,
   port_var = port_var,
   --origin_alias = origin_alias,
   portdb_path = portdb_path,
   wait_checksum = wait_checksum,
   moved_cache_load = moved_cache_load,
   lookup_moved_origin = lookup_moved_origin,
   list_prev_origins = list_prev_origins,
   load_default_versions = load_default_versions, -- MUST BE CALLED ONCE WITH ANY ORIGIN AS PARAMETER
   dump_cache = dump_cache,
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
