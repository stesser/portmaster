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

-- ----------------------------------------------------------------------------------
package.path = package.path .. ";/home/se/src/GIT/portmaster/?.lua"

-- ----------------------------------------------------------------------------------
local P = require ("posix")
local glob = P.glob

local P_PW = require ("posix.pwd")
local getpwuid = P_PW.getpwuid

local P_SL = require ("posix.stdlib")
local setenv = P_SL.setenv

local P_SS = require ("posix.sys.stat")
local stat = P_SS.stat
local lstat = P_SS.lstat
local stat_isdir = P_SS.S_ISDIR
local stat_isreg = P_SS.S_ISREG

local P_US = require ("posix.unistd")
local access = P_US.access
local chdir = P_US.chdir
local geteuid = P_US.geteuid
local getpid = P_US.getpid
local ttyname = P_US.ttyname

--[[
function trace (event, line)
   local s = debug.getinfo (2).short_src
   print (s .. ":" .. line)
end
debug.sethook (trace, "l")
--]]

-- R = require ("strict")

-- local _debug = require 'std._debug'(true)

Package = require ("Package")
Origin = require ("Origin")
local Options = require ("Options")
local Msg = require ("Msg")
local Progress = require ("Progress")
local Distfile = require ("Distfile")
local Action = require ("Action")
local Exec = require ("Exec")
local PkgDb = require ("PkgDb")

-- ----------------------------------------------------------------------------------
PROGRAM = arg[0]:gsub(".*/", "")
VERSION = "4.0.0a1" -- GLOBAL

-- ----------------------------------------------------------------------------------
stdin = io.stdin
tracefd = nil

-- ----------------------------------------------------------------------------------
setenv ("PID", getpid ())
setenv ("LANG", "C")
setenv ("LC_CTYPE", "C")
setenv ("CASE_SENSITIVE_MATCH", "yes")
setenv ("LOCK_RETRIES", "120")
-- setenv ("WRKDIRPREFIX", "/usr/work") -- ports_var ???

--[[
-- ----------------------------------------------------------------------------------
NUM = { -- GLOBAL
   actions = 0,
   deletes = 0,
   moves = 0,
   renames = 0,
   installs = 0,
   reinstalls = 0,
   upgrades = 0,
   delayed = 0,
   builds = 0,
   provides = 0,
}
]]

-- ----------------------------------------------------------------------------------
-- clean up when script execution ends
local function exit_cleanup (exit_code)
   exit_code = exit_code or 0
   -- echo EXIT_CLEANUP PID=$$ MASTER_PID=$PID >&3
   --  "$$" = "$PID" ] || exit 0
   Progress.clear ()
   Distfile.fetch_finish ()
   tempfile_delete ("FETCH_ACK")
   tempfile_delete ("BUILD_LOG")
   Options.save ()
   Msg.display ()
   if tracefd then
      io.close (tracefd)
   end
   os.exit (exit_code)
   -- not reached
end

-- abort script execution with an error message
function fail (...)
   Msg.show {start = true, "ERROR:", ...}
   Msg.show {"Aborting update"}
   exit_cleanup (1)
   -- not reached
end

local STARTTIMESECS = os.time ()
-- trivial trace function printing to stdout (UTIL)
local tracefd

function TRACE (...)
   if tracefd then
      local sep = ""
      local tracemsg = ""
      local t = {...}
      for i = 1, #t do
	 local v = t[i] or ("<" .. tostring (t[i]) .. ">")
	 v = tostring (v)
	 if v == "" or string.find (v, " ") then
	    v = "'" .. v .. "'"
	 end
	 tracemsg = tracemsg .. sep .. v
	 sep = " "
      end
      local dbginfo = debug.getinfo (3, "Sl") or debug.getinfo (2, "Sl")
      tracefd:write (tostring (os.time () - STARTTIMESECS) .. "	" .. (dbginfo.short_src or "(main)") .. ":" .. dbginfo.currentline .. "\t" .. tracemsg .. "\n")
   end
end

-- override LUA error function
function error (...)
   TRACE ("ERROR", ...)
   --error (...)
end

-- abort script execution with an internal error message on unexpected error
function fail_bug (...)
   Msg.show {"INTERNAL ERROR:", ...}
   Msg.show {"Aborting update"}
   exit_cleanup (10)
   -- not reached
end

-- remove trailing new-line, if any (UTIL) -- unused ???
function chomp (str)
   if str and str:byte(-1) == 10 then
      return str:sub (1, -2)
   end
   return str
end

--
function set_str (self, field, v)
   self[field] = v ~= "" and v or false
end

--
function set_bool (self, field, v)
   self[field] = (v and v ~= "" and v ~= "0") and true or false
end

--
function set_table (self, field, v)
   self[field] = v ~= "" and split_words (v) or false
end

-- ---------------------------------------------------------------------------------- (UTIL)
-- test whether the second parameter is a prefix of the first parameter (UTIL)
function strpfx (str, pattern)
   return str:sub(1, #pattern) == pattern
end

-- ----------------------------------------------------------------------------------
-- return flavor part of origin with flavor if present
function flavor_part (origin)
   return (string.match (origin, "%S+@([^:]+)"))
end

-- remove flavor part of origin to obtain a file system path
function dir_part (origin)
   return (string.match (origin, "^[^:@]+"))
end

-- optional make target component of port dependency or "install" if none
function target_part (dep)
   local target = string.match (dep, "%S+:(%a+)")
   return target or "install"
end

-- return list of all keys of a table -- UTIL
function table:keys ()
   local result = {}
   for k, v in pairs (self) do
      if type (k) ~= "number" then
	 table.insert (result, k)
      end
   end
   return result
end

-- return index of element equal to val or nil if not found
function table:index (list, val)
   for i, v in ipairs (list) do
      if v == val then
	 return i
      end
   end
   return nil
end

-- ---------------------------------------------------------------------------------- (UTIL)
-- create tempfile with a name that contains "$type" and the portmaster PID
function tempfile_create (type)
   local pattern = "pm-" .. getpid() .. "-" .. type
   local p = io.popen ("/usr/bin/mktemp -qt " .. pattern)
   local filename = p:read()
   p:close ()
   return filename
end

-- list temporary files created by the current process for "$type" (UTIL)
function tempfile_list (type, key)
   if not TMPDIR then
      return nil
   end
   local pattern = TMPDIR .. "pm-" .. getpid() .. "-" .. type .. "." .. (key or "*")
   return glob (pattern, GLOB_ERR)
end

-- delete all temporary files matching the passed parameters (may also be "*" for all)
function tempfile_delete (...)
   local files = tempfile_list (...)
   if files then
      for i, file in ipairs (files) do
	 os.remove (file)
      end
   end
end

-- directory name part of file path
function dirname (filename)
   return string.match (filename, ".*/") or "."
end

--
function log_caller (f)
   local d = debug.getinfo (3, "ln")
   TRACE ((d.name or "main") .. ":" .. d.currentline, "--", f)
end

--
JAILBASE = nil -- GLOBAL

-- ----------------------------------------------------------------------------------
-- some important paths and global parameters, can be overridden in the config file

--# set global variable to first parameter that is an executable command file and accepts option "-f /dev/stdin"
-- init_grep_cmd () {
-- 	global_var="$1"
-- 	shift
--
-- 	[ -n "$(getvar "$global_var")" ] && return
-- 	for cmd; do
-- 		if [ -f "$cmd" -a -x "$cmd" ]; then
-- 			echo "root" | $cmd -q -m 1 -f /dev/stdin /etc/passwd || continue
-- 			setvar "$global_var" "$cmd"
-- 			return 0
-- 		fi
-- 	done
-- 	fail_bug "Required parameter $global_var cannot be initialised."
-- }

-- concatenate file path, first element must not be empty
function path_concat (result, ...)
   TRACE ("PATH_CONCAT", result, ...)
   if result and result ~= "" then
      for i, v in ipairs ({...}) do
	 if string.sub (v, 1, 1) == "/" then
	    v = string.sub (v, 2)
	 end
	 if v and v ~= "" then
	    result = result .. (string.sub (result, -1) ~= "/" and "/" or "") .. v
	 end
      end
      TRACE ("PATH_CONCAT->", result)
      return result
   end
end

-- check whether path points to a directory
function is_dir (path)
   if path then
      local st, err = lstat (path)
      TRACE ("IS_DIR?", st, err)
      if st and access (path, "x") then
	 TRACE ("IS_DIR", path, stat_isdir (st.st_mode))
	 return stat_isdir (st.st_mode) ~= 0
      end
   end
end

--
function scan_dir (dir)
   local result = {}
   assert (dir, "empty directory argument")
   local files = glob (path_concat (dir, "*")) or {}
   for i, f in ipairs (files) do
      if is_dir (f) then
	 for i, f in ipairs (scan_dir (f)) do
	    table.insert (result, f)
	 end
      else
	 table.insert (result, f)
      end
   end
   return result
end

-- set global variable to first parameter that is a directory
function init_global_path (...)
   for i, dir in pairs ({...}) do
      if is_dir (path_concat (dir, ".")) then
	 if string.sub (dir, -1) ~= "/" then
	    dir = dir .. "/"
	 end
	 return dir
      end
   end
   error ("init_global_path")
end

-- return first parameter that is an existing executable
function init_global_cmd (...)
   for i, n in ipairs ({...}) do
      if access (n, "x") then
	 return n
      end
   end
   error ("init_global_cmd")
end

-- return global ports system variable (not dependent on any specific port)
-- might possibly have to support reading more than one line???
function ports_var (args)
   local exitcode, result
   table.insert (args, 1, "-f/usr/share/mk/bsd.port.mk")
   table.insert (args, 2, "-V")
   if not args.needbeforemk then
      table.insert (args, 1, "-DBEFOREPORTMK")
   end
   if Options.make_args then
      table.move (Options.make_args, 1, -1, #args + 1, args)
   end
   args.safe = true
   table.insert (args, 1, MAKE_CMD)
   result = Exec.run (args)
   --if result and strpfx (result, "make: ") then return nil end
   if args.table then
      return result
   elseif args.split then
      return split_words (result)
   else
      return chomp (result)
   end
end

-- initialize global variables after reading configuration files
-- return first existing directory with a trailing "/" appended
function init_globals ()
   -- os.chdir ("/")   -- NYI 	cd /

   -- important commands
   CHROOT_CMD		= init_global_cmd ("/usr/sbin/chroot")
   FIND_CMD		= init_global_cmd ("/usr/bin/find")
   LDCONFIG_CMD		= init_global_cmd ("/sbin/ldconfig")
   MAKE_CMD		= init_global_cmd ("/usr/bin/make")

   -- port infrastructure paths, may be modified by user
   PORTSDIR		= init_global_path (ports_var {"PORTSDIR"}, "/usr/ports")
   DISTDIR		= init_global_path (ports_var {"DISTDIR"}, path_concat (PORTSDIR, "distfiles"))
   DISTDIR_RO		= not access (DISTDIR, "rw") -- need sudo to fetch or purge distfiles

   PACKAGES		= init_global_path (Options.local_packagedir, ports_var {"PACKAGES"}, path_concat (PORTSDIR, "packages"), "/usr/packages")
   PACKAGES_BACKUP	= init_global_path (PACKAGES .. "portmaster-backup")
   PACKAGES_RO		= not access (PACKAGES, "rw") -- need sudo to create or delete package files

   LOCALBASE		= init_global_path (ports_var {"LOCALBASE"}, "/usr/local")
   LOCAL_LIB		= init_global_path (path_concat (LOCALBASE, "lib"))
   LOCAL_LIB_COMPAT	= init_global_path (path_concat (LOCAL_LIB, "compat/pkg"))

   PKG_DBDIR		= init_global_path (ports_var {needportmk = true, "PKG_DBDIR"}, "/var/db/pkg")	-- no value returned for make -DBEFOREPORTMK
   PKG_DBDIR_RO		= not access (PKG_DBDIR, "rw") -- need sudo to update the package database

   PORT_DBDIR		= init_global_path (ports_var {"PORT_DBDIR"}, "/var/db/ports")
   PORT_DBDIR_RO	= not access (PORT_DBDIR, "rw") -- need sudo to record port options

   WRKDIRPREFIX		= init_global_path (ports_var {"WRKDIRPREFIX"}, "/")
   WRKDIR_RO		= not access (path_concat (WRKDIRPREFIX, PORTSDIR), "rw") -- need sudo to build ports

   TMPDIR		= init_global_path (os.getenv ("TMPDIR"), "/tmp")

   -- 	cd "${PORTSDIR}" || fail "Cannot determine the base of the ports tree"
--   os.chdir (PORTSDIR) -- error check=?

   -- Bootstrap pkg if not yet installed
-- 	[ -x "${LOCALBASE}sbin/pkg-static" ] || ASSUME_ALWAYS_YES=yes /usr/sbin/pkg -v > /dev/null
   PKG_CMD		= init_global_cmd (path_concat (LOCALBASE, "sbin/pkg-static"))

   UID = geteuid ()
   local pw_entry = getpwuid (UID)
   USER = pw_entry.pw_name
   HOME = pw_entry.pw_dir
   TRACE ("PW_ENTRY", UID, EUID, USER, HOME)

   if not SUDO_CMD and UID ~= 0 then
      local cmd = Options.su_cmd or "sudo"
      SUDO_CMD = init_global_cmd (path_concat (LOCALBASE, "sbin", cmd), path_concat (LOCALBASE, "bin", cmd))
   end

   -- locate grep command that provided required functionality
   --GREP_CMD		= init_grep_cmd ("/usr/bin/bsdgrep", "/usr/bin/grep", "/usr/bin/gnugrep", LOCALBASE .. "/bin/grep")
   GREP_CMD		= "/usr/bin/grep"

   -- set package formats unless already specified by user
   Options.package_format = PACKAGE_FORMAT or "tgz"
   Options.backup_format = BACKUP_FORMAT or "tar"

   -- some important global variables
   ABI = chomp (Exec.run {safe = true, PKG_CMD, "config", "abi"})
   ABI_NOARCH = string.match (ABI, "^[^:]+:[^:]+:") .. "*"

   -- global variables for use by the distinfo cache and distfile names file (for ports to be built)
   DISTFILES_PERPORT = DISTDIR .. "DISTFILES.perport"	-- port names and names of distfiles required by the latest port version
   DISTFILES_LIST = DISTDIR .. "DISTFILES.list"	-- current distfile names of all ports

   -- has license framework been disabled by the user
   DISABLE_LICENSES = ports_var {"DISABLE_LICENSES"}

   -- load default versions of build and run tools
   --DEFAULT_VERSIONS = load_default_versions () ???

   -- sane default path
   setenv ("PATH", "/sbin:/bin:/usr/sbin:/usr/bin:$LOCALASE/sbin:$LOCALBASE/bin")

   setenv ("MAKE_JOBS_NUMBER", "4")
end

-- ----------------------------------------------------------------------------------
-- set sane defaults and cache some buildvariables in the environment
-- <se> ToDo convert to sub-shell and "export -p | egrep '^(VAR1|VAR2)'" ???
local function init_environment ()
   local output

   -- reset PATH to a sane default
   setenv ("PATH", "/bin:/sbin:/usr/bin:/usr/sbin:" .. LOCALBASE .. "bin:" .. LOCALBASE .. "sbin") -- DUPLICATE ???
   -- cache some build variables in the environment (cannot use ports_var due to its use of "-D BEFOREPORTMK")
   local env_param = Exec.run {safe = true, "make", "-f", "/usr/ports/Mk/bsd.port.mk", "-V", "PORTS_ENV_VARS"} -- || fail "$output" -- convert to port_var with extra parameter for the -f option argument XXX
   for i, var in ipairs (split_words (env_param)) do
      setenv (var, ports_var {var})
   end
   --
   --local env_lines = Exec.run {table = true, safe = true, "env", "SCRIPTSDIR=" .. PORTSDIR ..  "Mk/Scripts", "PORTSDIR=" .. PORTSDIR, "MAKE=make", "/bin/sh", PORTSDIR .. "Mk/Scripts/ports_env.sh"}
   local env_lines = Exec.run {table = true, safe = true, "env", "SCRIPTSDIR=" .. PORTSDIR ..  "Mk/Scripts", "PORTSDIR=" .. PORTSDIR, "MAKE=make", "/bin/sh", PORTSDIR .. "Mk/Scripts/ports_env.sh"}
   TRACE ("ENVLINES", table.unpack (env_lines))
   for i, line in ipairs (env_lines) do
      local var, value = line:match ("^export ([%w_]+)=(.+)")
      if string.sub(value, 1, 1) == '"' and string.sub (value, -1) == '"' then
	 value = string.sub (value, 2, -2)
      end
      setenv (var, value)
   end
   -- prevent delays for messages that are not displayed, anyway
   setenv ("DEV_WARNING_WAIT", "0")
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

-- set pkgname_old in outer frame based on origin_new
function pkgname_old_from_origin_new (origin_new)
   -- [ -n "$OPT_jailed" ] && return 1 # assume PHASE=build: the jails are empty, then
   -- first assume that the origin has not been changed
   local pkgname_old = origin_new:curr_pkg ()
   if pkgname_old then
      return pkgname_old
   end
   -- the new origin does not match any installed package, check MOVED
   local origin_old = origin_old_from_moved_to_origin (origin_new)
   if origin_old then
      pkgname_old = origin_old:curr_pkg ()
   end
   return pkgname_old -- may be nil
end

-- ----------------------------------------------------------------------------------
-- add line to success message to display at the end -- move message_*() to Msg module ???
SUCCESS_MSGS = {} -- GLOBAL
PKGMSG = {}

function message_success_add (text, seconds)
   if Options.dry_run then
      return
   end
   if not strpfx (text, "Provide ") then
      table.insert (SUCCESS_MSGS, text)
      if seconds then
	 seconds = "in " .. seconds .. " seconds"
      end
      Progress.show (text, "successfully completed", seconds)
      Msg.show {} -- or is Msg.show {""} required ???
   end
end

-- display all package messages that are new or have changed
function messages_display ()
   local packages = {}
   if Options.repo_mode then
      packages = table.keys (PKGMSG)
   end
   if packages or SUCCESS_MSGS then
      -- preserve current stdout and locally replace by pipe to "more" ???
      for i, pkgname in ipairs (packages) do
	 local pkgmsg = PkgDb.query {table = true, "%M", pkgname} -- tail +2
	 if pkgmsg then
	    Msg.show {start = true, "Post-install message for", pkgname .. ":"}
	    Msg.show {}
	    Msg.show {verbatim = true, table.concat (pkgmsg, "\n", 2)}
	 end
      end
      Msg.show {start = true, "The following actions have been performed:"}
      for i, line in ipairs (SUCCESS_MSGS) do
	 Msg.show {line}
      end
   end
   PKGMSG = nil -- required ???
end

--[[
-- try to find matching port origin (directory and optional flavor) given a passed in new origin and current package name
function origin_from_dir_and_pkg (origin_new, pkgname_old) -- move to Action module ???
-- 	local pkgname_new pkgname_base pkgname_major dir flavors flavor
--
   -- determine package name for given origin
   local pkgname_new = origin_new.pkg_new.name
   if pkgname_new then
      -- compare package names including major version numbers
      -- <se> TEST IST NOT CORRECT, E.G. for markdown-mode.el-emacs25-2.3_4 ==> markdown-mode
      local pkgname_major = pkgname_old.name_base_major
      if pkgname_major == pkgname_new.base_name_major then
	 return origin_new
      end
      -- try available flavors in search for a matching package name with same major version
      local dir = origin_new.port
      local flavors = port_flavors_get (origin_new)
      if flavors then
	 for i, flavor in ipairs (flavors) do
	    local origin_new = Origin:new (dir .. "@" .. flavor)
	    local pkgname_new = origin_new.pkg_new
	    -- compare package names including major version numbers
	    if pkgname_major == pkgname_new.name_base_major then
	       return origin_new
	    end
	    origin_new.pkg_new = nil
	 end
	 -- try available flavors in search for a matching package name ignoring the version number (in case major version has been incremented)
	 local pkgname_base = pkgname_old.name_base_major
	 if pkgname_base == pkgname_new.name_base then
	    return PkgDb.query {"%o", pkgname_old} -- is this correct ???
	 end
	 -- <se> is this additional search loop required? Better to fail if no packages with same major version?
	 local flavor = origin_new:flavor ()
	 if flavor then flavors:insert (1) end
	 for i, flavor in ipairs (flavors) do
	    local origin_new = Origin:new (dir .. "@" .. flavor)
	    local pkgname_new = origin_new.pkg_new
	    -- compare package names with version numbers stripped off
	    if pkgname_base == pkgname_new.name_base_major then
	       return origin_new
	    end
	    origin_new.pkg_new = nil
	 end
	 --
	 return Origin:new (origin_old:port_var {"PKGORIGIN"}) -- ???
      end
   end
   origin_new.pkg_new = nil
end
--]]

--[[ OBSOLETE ???
-- try to find origin in list of moved or deleted ports, returns new origin or "" followed by reason text
function origin_find_moved (origin_new)
   local origin = origin_new.name
   assert (origin, "origin is nil")
   -- passed in origin is default return value
   local lineno = 1
   local reason
   --TRACE ("grep", "-n", "'^" .. origin_new .. "|'", PORTSDIR .. "MOVED")
   while true do
      local line
      for l in Exec.run_pipe ("tail +" .. lineno, PORTSDIR .. "MOVED", "|", GREP_CMD, "-n", "'^" .. origin .. "|'") do
	 line = l
      end
      if not line then
	 break
      end
      lineno, origin, reason = line:match ("^(%d+):[%w-_/]+|([%w-_/^|]*)|[%d-]+|(.*)")
      lineno = tonumber (lineno) + 1
   end
--   if origin_new == "" then
--      origin_new = nil
--   end
   return Origin:new (origin), reason
end

-- set variable origin_new in external frame to new origin@flavor (if any) for given old origin@flavor (or to the old origin as default)
function origin_new_from_old (origin_old, pkgname_old)
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
function origin_from_dir (dir_glob)
   local result = {}
   for i, dir in Exec.run_pipe ("/bin/sh", "-c", "cd", PORTSDIR, ";", "echo", dir_glob) do
      local origin = Origin:new (dir:gsub(".*/([^/]+/([^/]+)$", "%1"))
      local name = origin:port_var {"PKGORIGIN"}
      if name then
	 result:insert (origin)
      end
   end
   return result
end
--]]

--[[
-- ----------------------------------------------------------------------------------
-- return all origin@flavor for port(s) in relative or absolute directory "$dir" (<se> TOO EXPENSIVE!!!) -- move to Origin module ???
function origin_old_from_port (port_glob)
   local dir_glob = port_glob:port ()
   local flavors = port_glob:flavor ()
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
--]]

--[[ OBSOLETE
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

-- return old origin@flavor for given new origin@flavor
function origin_old_from_moved_to_origin (origin_new)
--#	[ -n "$OPT_jailed" ] && return 1 # assume PHASE=build: the jail is empty, then
   local moved_file = PORTSDIR .. "MOVED"
   local lastline = ""
   for line in Exec.run_pipe (GREP_CMD, "'^[^|]+|" .. origin_new.name .. "|'", moved_file) do
      lastline = line
   end
   if lastline then
      local origin_old = string.match (lastline, "^([^|]+)|")
      return Origin:new (origin_old)
   end
end
--]]

-- ----------------------------------------------------------------------------------
-- split string on line boundaries and return as table
function split_lines (str)
   local result = {}
   for line in string.gmatch(str, "([^\n]*)\n?") do
      table.insert (result, line)
   end
   return result
end

-- split string on word boundaries and return as table
function split_words (str)
   if str then
      local result = {}
      for word in string.gmatch(str, "%S+") do
	 table.insert (result, word)
      end
      return result
   end
end

--[[
-- return checksum status without attempting to fetch any files -- is the test sufficient ???
function dist_checksums_ok (origin)
   print ("dist_checksums_ok", origin)
   local result = origin:port_make {table = true, safe = true, "-D", "NO_DEPENDS", "-D", "DEFER_CONFLICTS_CHECK", "-D", "DISABLE_CONFLICTS", "FETCH_CMD=true", "DEV_WARNING_WAIT=0", "checksum"}
   for i, line in ipairs (result) do
      if strpfx (line, "*** Error") then
	 return false
      end
   end
   return true
end
--]]

--[[
-- <se> use "make flavors-package-names" to list all package names for all (relevant) flavors
-- build_type: one of: auto, user, force, provide
-- dep_type: one of: build, run, base
function choose_action (build_type, dep_type, origin_old, origin_new, pkgname_old)
   TRACE ("\n----\nCHOOSE_ACTION", build_type, dep_type, tostring (origin_old), origin_new, pkgname_old)
   return Action:new {build_type = build_type, dep_type = dep_type, origin_old = Origin:new (origin_old), origin_new = Origin:new (origin_new), pkg_old = Package:new (pkgname_old)}
end
--]]

--# function port_identify_conflicts ()
--#	local origin="$1"
--#
--#	port_make "$origin"  -D BATCH -D NO_DEPENDS identify-install-conflicts
--#}

--[[
-- add the one port identified by the installed package name to the worklist
local function add_one_pkg (pkgname_old, origin_new) -- 2nd parameter is optional
   local build_type = Options.force and "force" or "auto"
   -- call choose_action with old origin and package name (new origin only if passed with -o)
   choose_action (build_type, "run", nil, origin_new, pkgname_old)
end

-- expand passed in pkgname or port glob (port glob with optional flavor)
local function add_with_globbing (args)
   local build_type = args.force and "force"
   local origin_new = args.origin_new -- ??? origin_new is actually never passed ...
   local origin_glob = args[1]
   local dir_glob = dir_part (origin_glob)
   local flavor = flavor_part (origin_glob)
   Msg.show {level = 1, start = true, "Checking upgrades for", origin_glob, "and ports it depends on ..."}
   -- first try to find installed packages matching the glob pattern
   local matches = PkgDb.query {table = true, glob = true, "%n-%v", dir_glob}
   if matches then
      for i, name in ipairs (matches) do
	 if not flavor or PkgDb.flavor_check (name, flavor) then
	    add_one_pkg (name, origin_new)
	 end
      end
      return matches
   end
   -- else try parameter as port directory or origin of uninstalled port(s)
   matches = {}
   for i, origin_new in ipairs (origin_from_dir (origin_glob)) do -- origin_from_dir should nsupport globs and return a list ???
      if choose_action (build_type, "run", "", origin_new) then
	 matches:insert (origin_new)
      end
   end
   return matches
end
--]]

-- replace passed package or port with one built from the new origin
local function ports_add_changed_origin (build_type, name, origin_new) -- 3rd arg is NOT optional
   if Options.force then
      build_type = "force"
   end
   Msg.show {level = 1, start = true, "Checking upgrades for", name, "and ports it depends on ..."}
   origins = PkgDb.origins_flavor_from_glob (name or PkgDb.origins_flavor_from_glob (name .. "*") or origin_old_from_port (name))
   assert (origins, "Could not find package or port matching " .. name)
   for i, origin_old in ipairs (origins) do
      choose_action (build_type, "run", origin_old, origin_new) -- && matched=1
   end
end

--[[
-- find origin of a port that depends on the origin passed as second parameter
local function origin_new_from_dependency (origin_old, origin_dep)
   assert (origin_dep)
   local depends = origin_old:depends ("all") --  "all" vs. "run" ???
   if table.index (depends, origin_dep) then
      return origin_old
   end
   local flavors = port_flavors_get (origin_old)
   if flavors then
      local dir = dir_part (origin_old)
      for i, flavor in ipairs (flavors) do
	 local origin = dir .. "@" .. flavor
	 depends = origin:depends ("run")
	 if table.index (depends, origin_dep) then
	    return origin
	 end
      end
   else -- EXPERIMENTAL <se> ???
      local flavor = flavor_part (origin_dep) or origin_dep:match (".*/(%w+)-.*")
      if flavor then
	 local origin = origin_old:match ("([^/]+/)") .. flavor .. origin_dep:match (".*/%w+-(.*)")
	 if origin ~= origin_old then
	    depends = origin:depends ("run")
	    if table.index (depends, origin_dep) then
	       return origin
	    end
	 end
      end
   end
   return nil
end

-- add installed package and all dependencies for the given origin (with optional flavor)
local function ports_add_recursive (name, origin_new) -- 2nd parameter is optional
-- 	local pkgnames pkgname pkgname_dep origin_old origin_old2 origin_new2
--
   Package.package_cache_load () -- initialize ORIGIN_OLD (with flavor) and PKGNAME_OLD
   Msg.show {level = 1, start = true, "Rebuilding", name, "and ports that depend on it, and upgrading ports they depend on ..."}
   local pkgnames = PkgDb.query {table = true, "%n-%v", name} or PkgDb.query {table = true, glob = true, "%n-%v", name .. "*"}
   assert (pkgnames, "Could not find package or port matching " .. name)
   --
   if origin_new then
      for i, pkgname in ipairs (pkgnames) do
	 local origin_old = PkgDb.origin_from_pkgname (pkgname)
	 FORCED_ORIGIN[origin_old] = origin_new
	 local depends = PkgDb.info ("-r", pkgname)
	 for i, pkgname_dep in ipairs (depends) do
	    local origin_old2 = PkgDb.origin_from_pkgname (pkgname_dep)
	    local origin_new2 = origin_new_from_dependency (origin_old2, origin_new)
	    if origin_new2 then
	       FORCED_ORIGIN[origin_old2] = origin_new2
	    end
	 end
      end
   end
   --
   local origins = table.keys (FORCED_ORIGIN)
   for i, origin_old in ipairs (origins) do
      -- log (0, "USE FORCED_ORIGIN", origin_old)
      choose_action ("force", "run", origin_old, FORCED_ORIGIN[origin_old], PkgDb.pkgname_from_origin (origin_old))
   end
   --
   for i, pkgname in ipairs (pkgnames) do
      local origin_old = PkgDb.origin_from_pkgname (pkgname)
      choose_action ("force", "run", origin_old, origin_new, pkgname)
   end
   -- <se> ToDo: if $origin_new is set, then the dependencies must be relative to the version built from that origin!!!
   for i, pkgname in ipairs (pkgnames) do
      local depends = PkgDb.info ("-r", pkgname)
      for j, pkgname_dep in ipairs (depends) do
	 local origin_old = PkgDb.origin_from_pkgname (pkgname_dep)
	 local origin_new2 = FORCED_ORIGIN[origin_old]
	 choose_action ("force", "run", origin_old, origin_new2, pkgname_dep)
      end
   end
end
--]]

--
local function ports_update (filters)
   local pkgs, rest = Package:installed_pkgs (), {}
   for i, filter in ipairs (filters) do
      for i, pkg in ipairs (pkgs) do
	 local selected, force = filter (pkg)
	 if selected then
	    Action:new {build_type = "user", dep_type = "run", force = force, pkg_old = pkg}
	 else
	    table.insert (rest, pkg)
	 end
      end
      pkgs, rest = rest, {}
   end
end

-- add all matching ports identified by pkgnames and/or portnames with optional flavor
local function ports_add_multiple (args)
   local pattern_table = {}
   for i, name_glob in ipairs (args) do
      local pattern = string.gsub (name_glob, "%.", "%%.")
      pattern = string.gsub (pattern, "%?", ".")
      pattern = string.gsub (pattern, "%*", ".*")
      table.insert (pattern_table, "^(" .. pattern .. ")")
   end
   local function filter_match (pkg)
      for i, v in ipairs (pattern_table) do
	 if string.match (pkg.name_base, v .. "$") then
	    return true
	 end
	 if pkg.origin and (string.match (pkg.origin.name, v .. "$") or string.match (pkg.origin.name, v .. "@%S+$")) then
	    return true
	 end
      end
   end
   TRACE ("PORTS_ADD_MULTIPLE-<", table.unpack (args))
   TRACE ("PORTS_ADD_MULTIPLE->", table.unpack (pattern_table))
   ports_update {
      filter_match,
   }
   for i, v in ipairs (args) do
      if string.match (v, "/") and access (path_concat (PORTSDIR, v, "Makefile"), "r") then
	 local o = Origin:new (v)
	 local p = o.pkg_new
	 Action:new {build_type = "user", dep_type = "run", force = Options.force, origin_new = o, pkg_new = p}
      end
   end
   --[[
   for i, name_glob in ipairs (args) do
      local filenames = glob (path_concat (PORTSDIR, name_glob, "Makefile"))
      if filenames then
	 for j, filename in ipairs (filenames) do
	    if access (filename, "r") then
	       local port = string.match (filename, "/([^/]+/[^/]+)/Makefile")
	       local origin = Origin:new (port)
	       Action:new {build_type = "user", dep_type = "run", origin_new = origin}
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
local function ports_add_all_outdated ()
   local current_libs = {}
   -- filter return values are: match, force
   local function filter_old_abi (pkg)
      return pkg.abi ~= ABI and pkg.abi ~= ABI_NOARCH, force
   end
   local function filter_old_shared_libs (pkg)
      if pkg.shared_libs then
	 for lib, v in pairs (pkg.shared_libs) do
	    return not current_libs[lib], true
	 end
      end
   end
   local function filter_is_required (pkg)
      return not pkg.is_automatic or pkg.num_depending > 0, false
   end
   local function filter_pass_all (pkg)
      return true, false
   end

   for i, lib in ipairs (PkgDb.query {table = true, "%b"}) do
      current_libs[lib] = true
   end
   ports_update {
      filter_old_abi,
      --filter_old_shared_libs,
      filter_is_required,
      filter_pass_all,
   }
end

-- ---------------------------------------------------------------------------
-- ask whether some file should be deleted (except when -n or -y enforce a default answer) -- move to Msg module -- convert to return table of files to delete?
function ask_and_delete (prompt, ...)
   local msg_level = 1
   if Options.default_no then
      answer = "q"
   end
   if Options.default_yes then
      answer = "a"
   end
   for i, file in ipairs (...) do
      if answer ~= "a" and answer ~= "q" then
	 answer = Msg.read_answer ("Delete " .. prompt .. " '" .. file .. "'", "y", {"y", "n", "a", "q"})
      end
      if answer == "a" then
	 msg_level = 0
      end
      --
      if answer == "a" or answer == "y" then
	 if Options.default_yes or answer == "a" then
	    Msg.show {level = msg_level, "Deleting", prompt .. ":", file}
	 end
	 if not Options.dry_run then
	    Exec.run {as_root = true, log = true, "/bin/unlink", file}
	 end
      elseif answer == "q" or answer == "n" then
	 if Options.default_no or answer == "q"  then
	    Msg.show {level = 1, "Not deleting", prompt .. ":", file}
	 end
      end
   end
end

-- ask whether some directory and its contents  should be deleted (except when -n or -y enforce a default answer)
function ask_and_delete_directory (prompt, ...) -- move to Msg module -- convert to return table of directories to delete?
   local msg_level = 1
   local answer
   if Options.default_no then
      answer = "q"
   end
   if Options.default_yes then
      answer = "a"
   end
   for i, directory in ipairs (...) do
      if answer ~= "a" and answer ~= "q" then
	 answer = Msg.read_answer ("Delete " .. prompt .. " '" .. directory .. "'", "y", {"y", "n", "a", "q"})
      end
      if answer == "a" then
	 msg_level = 0
      end
      --
      if answer == "a" or answer == "y" then
	 if Options.default_yes or answer == "a" then
	    Msg.show {level = msg_level, "Deleting", prompt .. ":", directory}
	 end
	 if not Options.dry_run then
	    if is_dir (directory) then
	       for i, file in ipairs (glob (directory .. "/*")) do
		  Exec.run {as_root = true, log = true, "/bin/unlink", file}
	       end
	       Exec.run {as_root = true, log = true, "/bin/rmdir", directory}
	    end
	 end
      elseif answer == "q" or answer == "n" then
	 if Options.default_no or answer == "q"  then
	    Msg.show {level = 1, "Not deleting", prompt .. ":", directory}
	 end
      end
   end
end

--# ----------------------------------------------------------------------------------
--# delete named package file in all direct sub-directories of $PACKAGES except in the portmaster-backup directory
--# function #delete_package ()
--#	(
--#		local pkgname="$1"
--#
--#		cd $PACKAGES
--#		ask_and_delete "stale package" $(find $(/bin/ls -1 | ${GREP_CMD} -E -v '^portmaster-backup$') -depth 1 -name "$pkgname.*")
--#	)
--#}

-- list package files in current directory (e.g. portmaster-backup) except for the newest one for each package
local function list_old_package_files ()
   -- create a list of packages with more than one package backup file
-- 	files = ls (-1Lt *-*.t?? 2>/dev/null)
-- 	duplicate_packages = echo ("$files" | sed -E 's|-[^-]*\.t..|-[^-]*\.t..|' | sort | uniq -d)
-- 	# for each package with multiple backups return names of all but the last modified file
-- 	for pattern in $duplicate_packages; do
-- 		echo "$files" | ${GREP_CMD} "^$pattern\$" | tail +2
-- 	done
-- }
   error("NYI")
end

-- # list package files for old versions in sub-directories of the current directory
local function list_stale_package_files ()
-- 	local tmpfile packages_pattern
--
-- 	tmpfile = tempfile_create (PKGS)
-- 	trap "unlink $tmpfile; Msg.start 0 'Aborted'; exit 0" INT
--
-- 	# create list of all package files (except those in directory portmaster-backup)
-- 	find $(/bin/ls -1 | ${GREP_CMD} -E -v '^portmaster-backup$') -type f -name "*-*.t??" | sort > "$tmpfile"
--
-- 	# create list of package files not corresponding to installed packages
-- 	packages_pattern = PkgDb.query ("%n-%v" | sed -E 's|^|/|;s!(\.|\[|\]|\{|\})!\\\1!g;s|$|\\.t..$|')
--
-- 	# the following "grep" takes an extremely long time to run with LANG=C and/or LC_CTYPE=C (affects only the GNU grep in FreeBSD!)
-- 	echo "$packages_pattern" | ${GREP_CMD} -vf /dev/stdin "$tmpfile"
-- 	unlink "$tmpfile"
-- }
   error("NYI")
end

-- # delete package files that do not belong to any currently installed port (except portmaster backup packages)
local function packagefiles_purge () -- move to new PackageFile module ???
-- 	(
-- 		local stale_packages dir
--
-- 		cd "$PACKAGES" || fail "No packages directory $PACKAGES found"
--
-- 		Msg.start 0 "Scanning $PACKAGES for stale package files ..."
-- 		stale_packages = list_stale_package_files)
-- (
-- 		if [ -n "$stale_packages" ]; then
-- 			ask_and_delete "stale package file" $stale_packages
-- 		else
-- 			msg 0 "No stale package files found"
-- 		fi
-- 		# only keep the newest file fir each package
-- 		for dir in *; do
-- 			[ -d "$dir" ] || continue
-- 			[ "$dir" = "portmaster-backup" ] && continue
-- 			(
-- 				cd "$dir"
-- 				list_old_package_files | xargs -n1 unlink
-- 			)
-- 		done
--
-- 		# silently delete stale symbolic links pointing to now deleted package files
-- 		RUN_SU ${FIND_CMD} . -type l | xargs -n1 -I% sh -c '[ -e "%" ] || unlink "%"'
-- 		# delete empty package sub-directories
-- 		RUN_SU ${FIND_CMD} . -type d -empty -delete
--
-- 		cd "$PACKAGES/portmaster-backup" 2>/dev/null || return
--
-- 		Msg.start 0 "Scanning $PACKAGES/portmaster-backup for stale backup package files ..."
-- 		stale_packages = list_old_package_files)
-- 		(if [ -n "$stale_packages" ]; then
-- 			ask_and_delete "stale package backup file" $stale_packages
-- 		else
-- 			msg 0 "No stale backup packages found"
-- 		fi
-- 	)
-- }
   error("NYI")
end

-- ----------------------------------------------------------------------------------
local function list_stale_libraries ()
   -- create list of shared libraries used by packages and create list of compat libs that are not required (anymore)
   local activelibs = {}
   local lines = PkgDb.query {table = true, glob = true, "%B", "*"}
   for i, lib in ipairs (lines) do
      activelibs[lib] = true
   end
   -- list all active shared libraries in some compat directory
   local compatlibs = {}
   local ldconfig_lines = Exec.run {table = true, safe = true, "ldconfig", "-r"} -- safe flag required ???
   for i, line in ipairs (ldconfig_lines) do
      local lib = line:match (" => " .. LOCALBASE .. "lib/compat/pkg/(.*)")
      if lib and not activelibs[lib] then
	 compatlibs[lib] = true
      end
   end
   return table.keys (compatlibs)
end

-- delete stale compat libraries (i.e. those no longer required by any installed port)
local function shlibs_purge ()
   Msg.show {start = true, "Scanning for stale shared library backups ..."}
   local stale_compat_libs = list_stale_libraries ()
   if #stale_compat_libs then
      table.sort (stale_compat_libs)
      ask_and_delete ("stale shared library backup", stale_compat_libs)
   else
      Msg.show {"No stale shared library backups found."}
   end
end

-- ----------------------------------------------------------------------------------
-- delete stale options files
local function portdb_purge ()
   Msg.show {start = true, "Scanning", PORT_DBDIR, "for stale cached options:"}
   local origins = {}
   local origin_list = PkgDb.query {table = true, "%o"}
   for i, origin in ipairs (origin_list) do
      local subdir = origin:gsub ("/", "_")
      origins[subdir] = origin
   end
   assert (chdir (PORT_DBDIR), "cannot access directory " .. PORT_DBDIR)
   local stale_origins = {}
   for i, dir in ipairs (glob ("*")) do
      if not origins[dir] then
	 table.insert (stale_origins, dir)
      end
   end
   if #stale_origins then
      ask_and_delete_directory ("stale port options file for", stale_origins)
   else
      Msg.show {"No stale entries found in", PORT_DBDIR}
   end
   chdir ("/")
end

-- list ports (optionally with information about updates / moves / deletions)
local function list_ports (mode)
   local filter = {
      {
	  "root ports (no dependencies and not depended on)",
	  function (pkg)
	     return pkg.num_depending == 0 and pkg.num_dependencies == 0 and pkg.is_automatic == false
	  end
      },
      {
	 "trunk ports (no dependencies but depended on)",
	 function (pkg)
	    return pkg.num_depending ~= 0 and pkg.num_dependencies == 0
	 end
      },
      {
         "branch ports (have dependencies and are depended on)",
	 function (pkg)
	    return pkg.num_depending ~= 0 and pkg.num_dependencies ~= 0
	 end
      },
      {
         "leaf ports (have dependencies but are not depended on)",
	 function (pkg)
	    return pkg.num_depending == 0 and pkg.num_dependencies ~= 0 and pkg.is_automatic == false
	 end
      },
      {
         "left over ports (e.g. build tools that are not required at run-time)",
	 function (pkg)
	    return pkg.num_depending == 0 and pkg.is_automatic == true
	 end
      },
   }

   local pkg_list = Package:installed_pkgs ()
   table.sort (pkg_list, function (a, b) return a.name > b.name end)
   Msg.show {start = true, "List of installed packages by category:"}
   for i, f in ipairs (filter) do
      local descr = f[1]
      local test = f[2]
      local rest = {}
      local first = true
      local count = 0
      for k, pkg_old in ipairs (pkg_list) do
	 if test (pkg_old) then
	    count = count + 1
	 end
      end
      if count > 0 then
	 for k, pkg_old in ipairs (pkg_list) do
	    if test (pkg_old) then
	       local line = pkg_old.name
	       if mode == "verbose" then
		  local origin_old = pkg_old.origin
		  assert (origin_old, "no origin for package " .. pkg_old.name)
		  local pkg_new = origin_old.pkg_new
		  local pkgname_new = pkg_new and pkg_new.name
		  local reason
		  if not pkgname_new then
		     local origin_new = origin_old:lookup_moved_origin ()
		     reason = origin_old.reason
		     TRACE ("MOVED??", reason)
		     if origin_new and origin_new ~= origin_old then
			pkg_new = origin_new.pkg_new
			pkgname_new = pkg_new and pkg_new.name
		     end
		  end
		  if not pkgname_new then
		     if reason then
			line = line .. " has been removed: " .. reason
		     else
			line = line .. " cannot be found in the ports system"
		     end
		  elseif pkgname_new ~= pkg_old.name then
		     line = line .. " needs update to " .. pkgname_new
		  end
	       end
	       if first then
		  Msg.show {start = true, count, descr}
		  first = false
	       end
	       Msg.show {line}
	    else
	       table.insert (rest, pkg_old)
	    end
	    --end
	 end
	 pkg_list = rest
      end
   end
   assert (pkg_list[1] == nil, "not all packages covered in tests")
end

-- ----------------------------------------------------------------------------------
--TRACEFILE = "/tmp/pm.cmd-log" -- DEBUGGING EARLY START-UP ONLY -- GLOBAL

-- ----------------------------------------------------------------------------------
local function main ()
   --print (umask ("755")) -- ERROR: results in 7755, check the details of this function
   --shell ({to_tty = true}, "umask")

   -- load option definitions from table
   Options.init ()

   -- initialise global variables based on default values and rc file settings
   init_globals ()

   -- do not ask for confirmation if not connected to a terminal
   if not ttyname (0) then
      stdin = io.open("/dev/tty", "r")
      if not stdin then
	 Options.no_confirm = true
      end
   end

   -- disable setting the terminal title if output goes to a pipe or file (fd=3 is remapped from STDOUT)
   if not ttyname (2) then
      Options.no_term_title = true
   end
   -- initialize environment variables based on globals set in prior functions
   init_environment ()

   -- TESTING
   if TEST then TEST () end

   -- ----------------------------------------------------------------------------------
   -- plan tasks based on parameters passed on the command line
   PHASE = "scan"

   if Options.replace_origin then
      if #arg ~= 1 then
	 error ("xactly one port or packages required with -o")
      end
      ports_add_changed_origin ("force", arg, Options.replace_origin)
   elseif Options.all then
      ports_add_all_outdated ()
   elseif Options.all_old_abi then
      ports_add_all_old_abi () -- create from ports_add_all_outdated() ???
   end

   --  allow the specification of -a and -r together with further individual ports to install or upgrade
   if #arg > 0 then
      arg.force = Options.force
      ports_add_multiple (arg)
   end

   -- add missing dependencies
   Action.add_missing_deps ()

   -- sort actions according to registered dependencies
   Action.sort_list ()

   --[[
   -- DEBUGGING!!!
   Origin.dump_cache ()
   Package.dump_cache ()
   Action.dump_cache ()
   --]]

   -- end of scan phase, all required actions are known at this point, builds may start
   PHASE = "build"

   Action.execute ()

   -- ----------------------------------------------------------------------------------
   -- non-upgrade operations supported by portmaster - executed after upgrades if requested
   if Options.check_depends then
      Exec.run {to_tty = true, "pkg", "check", "-dn"}
   end
   if Options.list then
      list_ports (Options.list)
   end
   if Options.list_origins then
      PkgDb.list_origins ()
   end
-- if Options.delete_build_only then delete_build_only () end -- should have become obsolete due to build dependency tracking
   if Options.clean_stale_libraries then
      shlibs_purge ()
   end
-- if Options.clean_compat_libs then clean_stale_compat_libraries () end -- NYI
   if Options.clean_packages then
      packagefiles_purge ()
   end
   if Options.deinstall_unused then
      packages_delete_stale ()
   end
   if Options.check_port_dbdir then
      portdb_purge ()
   end
-- if Options.expunge then expunge (Options.expunge) end
   if Options.scrub_distfiles then
      distfiles_clean_stale ()
   end

   -- display package messages for all updated ports
   exit_cleanup (0)
   -- not reached
end

tracefd = io.open ("/tmp/pm.log", "w")

-- --[[
-- ---------------------------------------------------------------------------
-- TESTING
function TEST_ ()
   local function table_values (t) return "[" .. table.concat (t, ",") .. "]" end
   local o = Origin:new ("devel/py-setuptools@py27")
   print ("TEST:", o, o.pkg_new, o.is_broken, o.is_ignore, o.is_forbidden, table_values (o.flavors), o.flavor)
   local o = Origin:new ("devel/py-setuptools@py36")
   Action:new {build_type = "user", dep_type = "run", origin_new = o}
   print ("OLD ORIGINS:", table_values (o:list_prev_origins()))

   --[[
   local o = Origin:new ("devel/ada-util")
   print ("TEST:", o, table_values (o.old_pkgs), o.pkg_new, o.is_broken, o.is_ignore, o.is_forbidden, table_values (o.flavors), o.flavor)
   print ("TEST:", o, table_values (o.old_pkgs), o.pkg_new, o.is_broken, o.is_ignore, o.is_forbidden, table_values (o.flavors), o.flavor)
   local o = Origin:new ("devel/py-setuptools@py27")
   print ("TEST:", o, table_values (o.old_pkgs), o.pkg_new, o.is_broken, o.is_ignore, o.is_forbidden, table_values (o.flavors), o.flavor, table_values (o.conflicts))
   local p = table_values (o.old_pkgs)
   print ("TEST2:", o, p, p.origin, p.is_locked, p.is_automatic, p.num_dependencies, p.num_depending, p.abi, table_values (p.categories), table_values (p.shlibs))
   print (table_values (p.files), table_values (o.build_depends), table_values (o.run_depends))
   local o = Origin:new ("math/gnubc")
   print ("TEST3:", o, table_values (o.old_pkgs), o.pkg_new, o.is_broken, o.is_ignore, o.is_forbidden, table_values (o.flavors), o.flavor, table_values (o.conflicts), o.distinfo_file, o.license)
   local o = Origin:new ("multimedia/ffmpeg")
   print ("TEST4:", table_values (o.all_options), table_values (o.port_options))
   --]]
   local o = Origin:new ("devel/py-setuptools27")
   print ("M", o, o:lookup_moved_origin())
   local o = Origin:new ("www/py-blogofile")
   print ("M", o, o:lookup_moved_origin())
   local o = Origin:new ("devel/qca@qt5")
   print ("M", o, o:lookup_moved_origin())
   local o = Origin:new ("devel/eric6@qt4_py37")
   print ("M", o, o:lookup_moved_origin())
   local o = Origin:new ("archivers/par2cmdline-tbb")
   print ("M", o, o:lookup_moved_origin())
   local o = Origin:new ("shells/bash")
   print ("M", o, o:lookup_moved_origin())
end
--]]

local success, errmsg = xpcall (main, debug.traceback)
if not success then
   fail (errmsg)
end
os.exit (0)

-- # ToDo
-- # adjust port origins in stored package manifests (but not in backup packages)
-- # ???automatically rebuild ports after a required shared library changed (i.e. when an old library of a dependency was moved to the backup directory)
-- #      ---> pkg query "%B %n-%v" | grep $old_lib
-- #
--
-- # use "pkg query -g "%B" "*" | sort -u" to get a list of all shared libraries required by the installed packages and remove all files not in this list from lib/compat/pkg.
-- # Additionally consider all files that still require libs in /lib/compat/pkg as outdated, independently of any version changes.
--
-- # Check whether FLAVORS have been removed from a port before trying to build it with a flavor. E.g. the removal of "qt4" caused ports with FLAVORS qt4 and qt5 to become qt5 only and non-flavored
--
-- # In jailed or repo modes, a full recursion has to be performed on run dependencies (of dependencies ...) or some deep dependencies may be missed and run dependencies of build dependencies may be missing
--
-- # BUGS
-- #
-- # -x does not always work (e.g. when a port is to be installed as a new dependency)
-- # installing port@flavor does not always work, e.g. the installation of devel/py-six@py36 fails if devl/py-six@py27 is already installed
-- # conflicts detected only in make install (conflicting files) should not cause an abort, but be delayed until the conflicting package has been removed due to being upgraded
-- #	in that case, the package of new new conflicting port has already been created and it can be installed from that (if the option to save the package had been given)
-- #
-- # -o <origin_new> -r <name>: If $origin_new is set, then the dependencies must be relative to the version built from that origin!!!
--
-- # --delayed-installation does not take the case of a run dependency of a build dependency into account!
-- # If a build dependency has run dependencies, then these must be installed as soon as available, as if they were build dependencies (since they need to exist to make the build dependency runnable)
--
-- # --force or --recursive should prevent use of already existing binaries to satisfy the request - the purpose is to re-compile those ports since some dependency might have incompatibly changed
--
-- # failure in the configuration phase (possibly other phases, too) lead to empty origin_new and then to a de-installation of the existing package!!! (e.g. caused by update conflict in port's Makefile)
--
-- # restart file: in jailed/repo-mode count only finished "build-only" packages as DONE, but especially do not count "provided" packages, which might be required as build deps for a later port build
--
--
-- # General build policy rules (1st match decides!!!):
-- #
-- # Build_Dep_Flag := Build_Type = Provide
-- # UsePkgfile_Flag := Build_Type != Force && Pkgfile exists
-- # Late_Flag := Delayed/Jailed && Build_Dep=No
-- # Temp_Flag := Direct/Delayed && Run_Dep=No && Force=No && User=No
-- #
-- # ERROR:
-- #	Run_Dep=No && Build_Dep=No
-- #	Run_Dep=No && Build_Type=User
-- #
-- # Jail_Install:
-- #	Mode=Jailed/Repo && Build_Dep=Yes
-- #
-- # Base_Install:
-- #	Mode=Direct/Delayed/Jailed && Upgrade=Yes
-- #	Mode=Direct/Delayed/Jailed && Build_Type=Force
-- #
-- #	|B_Type	| B_Dep	| R_Dep	| Upgr	|   JailInst
-- # Mode	| A F U	|  Y N	|  Y N	|  Y N	|InJail	|cause
-- # ------|-------|-------|-------|-------|-------|-------
-- #  *	| A F U	|    N	|    N	|   -	| ERROR	|-
-- #  *	|     U	|   -	|    N	|   -	| ERROR	|-
-- #  D/L	| A F U	|   -	|   -	|   -	|   -	|NoJail
-- #  J/R	| A F U	|    N	|  Y	|   -	|   -	|BuildNo
-- #  J/R	| A F U	|  Y	|   -	|   -	|  Yes	|Build
-- #
-- # 	|B_Type	| B_Dep	| R_Dep	| Upgr	|    BaseInst
-- # Mode	| A F U	|  Y N	|  Y N	|  Y N	|InBase	| P J B R F U
-- # ------|-------|-------|-------|-------|-------|------------
-- #  D/L	| A	|  Y	|    N	|  Y	| Temp	| - - B - - U
-- #  L/J	|   F  	|    N	|  Y	|   -	| Late	| -   - R F
-- #  L/J	| A   U	|    N	|  Y	|  Y	| Late	| -   - R - U
-- #  D/L	|   F  	|   -	|   -	|   -	|  Yes	| - -     F
-- #  D/L	| A   U	|   -	|   -	|  Y	|  Yes	| - -     - U
-- #  L/J	|   F  	|  Y	|  Y	|   -	|  Yes	| -   B R F
-- #  L/J	| A   U	|  Y	|  Y	|  Y	|  Yes	| -   B R - U
--
-- # Usage_Mode:
-- # D = Direct installation
-- # L = deLayed installation
-- # J = Jailed build
-- # R = Repository mode
--
-- # Build_Type:
-- # A = Automatic
-- # F = Forced
-- # U = User request
--
-- # Installation_Mode (BaseInst):
-- # Temp = Temporary installation
-- # Late = Installation after completion of all port builds
-- # Yes  = Direct installation from a port or package
--
-- # ----------------------------------------------------------------------------
-- #
-- # Build-Deps:
-- #
-- # For jailed builds and if delete-build-only is set:
-- # ==> Register for each dependency (key) which port (value) relies on it
-- # ==> The build dependency (key) can be deleted, if it is *not also a run dependency* and after the dependent port (value) registered last has been built
-- #
-- # Run-Deps:
-- #
-- # For jailed builds only (???):
-- # ==> Register for each dependency (key) which port (value) relies on it
-- # ==> The run dependency (key) can be deinstalled, if the registered port (value) registered last has been deinstalled
-- #
--
-- # b r C D J -----------------------------------------------------------------------------
--
-- # b r C     classic port build and installation:
-- # b r C      - recursively build/install build deps if new or version changed or forced
-- # b r C      - build port
-- # b r C      - create package
-- # b r C      - deinstall old package
-- # b r C      - install new version
-- # b r C      - recursively build/install run deps if new or version changed or forced
-- #
-- # b r C     classic package installation/upgrade:
-- # b r C      - recursively provide run deps (from port or package)
-- # b r C      - deinstall old package
-- # b r C      - install new package
--
-- # b r   D   delay-installation port build (of build dependency):
-- # b r   D    - recursively build/install build deps if new or version changed or forced
-- # b r   D    - build port
-- # b r   D    - create package
-- # b r   D    - deinstall old package
-- # b r   D    - install new version
-- # b r   D    - recursively build/install run deps if new or version changed or forced
-- #
-- #   r   D   delay-installation port build (not a build dependency):
-- #   r   D    - recursively build/install build deps if new or version changed or forced
-- #   r   D    - build port
-- #   r   D    - create package
-- #   r   D    - register package for delayed installation / upgrade
--
--
-- # b     D    - recursively build/install build deps if new or version changed or forced
-- # b     D    - build port
-- # b     D    - create package
-- # b     D    - deinstall old package
-- # b     D    - install new version
-- # b     D    - recursively build/install run deps if new or version changed or forced
-- #
-- #
-- #
-- # b     D   delay-installation package installation (of build dependency):
-- # b     D    - recursively build/install run deps
-- # b     D    - deinstall old package
-- # b     D    - install new version
-- #       D
-- #   r   D   delay-installation package installation (not a build dependency):
-- #   r   D    - register package for delayed installation / upgrade
--
-- # b       J jailed port build (of build dependency):
-- # b       J  - recursively build/install build deps in jail
-- # b       J  - build port
-- # b       J  - create package
-- # b       J  - install new version in jail
-- # b       J  - recursively build/install run deps in jail
-- # b       J  - register package for delayed installation / upgrade
-- #
-- #   r     J jailed port build (not a build dependency):
-- #   r     J  - recursively build/install build deps in jail
-- #   r     J  - build port
-- #   r     J  - create package
-- #   r     J  - register package for delayed installation / upgrade
-- #
-- #
-- # b       J jailed package installation (of build dependency):
-- # b       J  - recursively build/install run deps in jail
-- # b       J  - install package in jail
-- # b       J  - register package for delayed installation / upgrade depending on user options
-- #
-- #   r     J jailed package installation (not a build dependency):
-- #   r     J  - register package for delayed installation / upgrade
--
-- #           repo-mode is identical to jailed builds but without installation in base
--
-- # -----------------------
-- # Invocation of "make -V $VAR" - possible speed optimization: query multiple variables and cache result
-- #
-- # --> register_depends
-- # origin_var "$dep_origin" FLAVOR
-- #
-- # # --> origin_from_dir
-- # origin_var "$dir" PKGORIGIN
-- #
-- # # --> dist_fetch_overlap
-- # origin_var "$origin" ALLFILES
-- # origin_var "$origin" DIST_SUBDIR
-- #
-- # # --> distinfo_update_cache
-- # origin_var "$origin" DISTINFO_FILE
-- #
-- # # --> port_flavors_get
-- # origin_var "$origin" FLAVORS
-- #
-- # # --> port_is_interactive
-- # origin_var "$origin_new" IS_INTERACTIVE
-- #
-- # # --> check_license
-- # origin_var "$origin_new" LICENSE
-- #
-- # # --> *
-- # origin_var "$origin_new" PKGNAME
-- #
-- # # --> package_check_build_conflicts
-- # origin_var "$origin_new" BUILD_CONFLICTS
-- #
-- # # --> choose_action, (list_ports)
-- # origin_var "$origin_old" PKGNAME
-- #
-- # # --> origin_from_dir_and_pkg
-- # origin_var "$origin_old" PKGORIGIN
-- #
-- # # --> choose_action
-- # origin_var_jailed "$origin_old" PKGNAME
-- #
-- # # --> choose_action, origin_from_dir_and_pkg
-- # origin_var_jailed "$origin_new" PKGNAME

--[[
Ports with special dependencies:

-- fetch:
databases/mysql-q4m				${_MYSQL_SERVER}:fetch
graphics/gd					x11-fonts/geminifonts:fetch

-- checksum:
math/atlas					math/lapack:checksum

-- extract:
devel/elfutils					devel/gnulib:extract
devel/p5-Thrift					devel/thrift:extract
graphics/aseprite				x11/pixman:extract
irc/gseen.mod					irc/eggdrop16:extract
print/fontforge					print/freetype2:extract
russian/p5-XML-Parser-encodings			converters/iconv-extra:extract
russian/p5-XML-Parser-encodings			converters/iconv:extract
www/publicfile					databases/cdb:extract

-- patch:
audio/chromaprint				devel/googletest:patch
audio/liblastfm-qt5				math/fftw3:patch
databases/lua-lsqlite3				databases/sqlite3:patch
databases/py-sqlrelay				${SQLRELAY_PORTDIR}:patch
databases/zabbix3-libzbxpgsql			net-mgmt/${PKGNAMEPREFIX}agent:patch
devel/py-omniorb				devel/omniORB:patch
games/freeminer					x11-toolkits/irrlicht:patch
games/minetest					x11-toolkits/irrlicht:patch
net/istgt					emulators/virtualbox-ose:patch
net/relayd					security/libressl:stage
net/tigervnc-server				x11-servers/xorg-server:patch
sysutils/fusefs-rar2fs				${LIBUNRAR_PORT}:patch
textproc/ruby-rd-mode.el			textproc/ruby-rdtool:patch

-- configure:
astro/boinc-astropulse				astro/boinc-setiathome:configure
audio/pulseaudio-module-xrdp			audio/pulseaudio:configure
databases/mroonga				${_MYSQL_SERVER}:configure
devel/git-cinnabar				devel/git:configure
textproc/libxml2-reference			textproc/libxml2:configure
textproc/libxslt-reference			textproc/libxslt:configure

-- build:
databases/mysql-q4m				${_MYSQL_SERVER}:build
finance/gnucash					devel/googletest:build
net-mgmt/nagios-check_memcached_paranoid	${PLUGINS}:build
print/ft2demos					print/freetype2:build

-- stage:
net/openntpd					security/libressl:stage
security/dsniff					security/libressl:stage

--]]

--[[
Actions / Use Cases:
   build (in base or jail)
   deinstall old package (from base)
   deinstall new package (from jail)
   create new package (from base or jail)
   create backup package (from base)
   install from work directory (to base)
   install from package file (to base or jail)
   ignore
   change origin
   change package name

Action States:
   planned
   built (in jail or base system)
   installed (in base system)
   skipped
   failed

Dependency Tracking State:
   is build dependency
   is run dependency
   is run dependency of build dependency
   is forced
   is automatic (not directly requested by user)

non-jailed/delay-installation:
   build new port
   create package file from just built port
   install or upgrade from just built port
   install or upgrade from package file
   deinstall package
   ignore locked, excluded or broken port
   change port directory in package database
   change package name in package database
   states: patched, staged, installed

jailed/repo-mode:
   build new port in jail
   create package file from port built in jail
   install or upgrade from port built in jail
   provide package file in jail as build dependency (or as run dependency of a build dependency)
   deinstall build dependencies from jail after last use (before start of next port build)
   ignore locked, excluded or broken port
   states: patched, staged, package built, package installed to base system
]]
