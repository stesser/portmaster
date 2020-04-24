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
-- options and rc file processing
local Options = {}
local LONGOPT = {}

-- print the long options ordered by associated short option followed by sorted list of longopts without short option
local function print_longopts ()
   local result = {}
   local longopts = table.keys (LONGOPT)
   table.sort (longopts)
   for i, v in ipairs (longopts) do
      table.insert (result, LONGOPT[v])
   end
   longopts = table.keys (VALID_OPTS)
   table.sort (longopts)
   for i, v in ipairs (longopts) do
      if VALID_OPTS[v][1] == nil then
	 table.insert (result, v)
      end
   end
   return result
end

-- print version and usage message
local function usage ()
   -- print_version ()
   -- print ()
   io.stderr:write ("Usage: " .. PROGRAM .. " [option ...] [portorigin|packagename] ...\n\nOptions:\n")
   local options_descr = {}
   local maxlen = 0
   for i, longopt in pairs (print_longopts ()) do
      local line = ""
      local spec = VALID_OPTS[longopt]
      local shortopt = spec[1]
      local param = spec[2]
      local descr = spec[3]
      local action = spec[4]
      if shortopt then
	 line = "-" .. shortopt
	 if param then
	    line = line .. " <" .. param .. ">"
	 end
	 line = line .. " | "
      end
      line = line .. "--" .. longopt:gsub ("_", "-")
      if param then
	 line = line .. "=<" .. param .. ">"
      end
      table.insert (options_descr, {line, descr})
      if #line > maxlen then
	 maxlen = #line
      end
   end
   for i, v in ipairs (options_descr) do
      io.stderr:write (string.format (" %-" .. maxlen + 1 .. "s %s\n", v[1], v[2]))
   end
   os.exit (2)
end

--
local function opt_err (opt)
   io.stderr:write ("Unknown option '" .. opt .. "'\n\n")
   usage ()
end

-- 
local function opt_check (opt)
   if VALID_OPTS[opt] then
      return opt
   elseif opt then
      opt = LONGOPT[opt]
      if opt then
	 return opt
      end
   end
   error ("Invalid option " .. opt, 2)
end

-- process long option of type "--longopt=param" with optional param
local function longopt_action (opt, arg)
   local opt_rec = VALID_OPTS[opt]
   if not opt_rec then
      opt_err (opt)
   end
   param = opt_rec[2]
   if param then
      assert (arg and #arg > 0, "required parameter is missing")
   else
      -- assert (not arg or #arg == 0, "parameter '" .. arg .. "' is unexpected")
      if arg == "no" then
	 arg = nil else arg = opt
      end
   end
   opt_rec[4] (opt, arg)
end

-- process short option of type "-o param" with optional param
local function shortopt_action (opt, arg)
   local longopt = LONGOPT[opt]
   if not longopt then
      opt_err (opt)
   end
   longopt_action (longopt, arg)
end

-- 
local function rcfile_tryload (filename)
   local inp = io.open (filename, "r")
   if not inp then
      return
   end
   local lineno = 0
   for line in inp:lines("*l") do
      lineno = lineno + 1
      line = line:gsub("#.*", "")
      if #line > 0 then
	 local opt, value = string.match (line, "([^#%s]+)%s*=%s*(%S*)")
	 if opt then
	    if OLD_RC_COMPAT[opt] then
	       opt = OLD_RC_COMPAT[opt]
	    elseif strpfx (opt, "PM_") then
	       error ("unsupported old option")
	    else
	       opt = string.lower (opt:gsub("-", "_"))
	       opt = opt_check (opt)
	       assert (opt)
	    end
	    value = value or "no"
	    if string.lower (value) == "no" then
	       value = "no"
	    end
	    longopt_action (opt, value)
	 end
      end
   end
end

-- set package format option with check for supported values
local VALID_FORMATS = { tar = true, tgz = true, tbz = true, txz = true }

local function set_package_format (var, fmt)
   assert (VALID_FORMATS[fmt], "invalid package format '" .. fmt .. "'")
   Options[var] = fmt
end

-- set option (or clear, if value is nil)
local function opt_set (opt, value)
   Options[opt] = value
end

-- append passed value to option string
local function opt_add (opt, value)
   local t = Options[opt] or {}
   table.insert (t, value)
   Options[opt] = t
end

-- clear passed option, with message if cause is provided
local function opt_clear (opt, cause)
   if Options[opt] then
      if cause then
	 Msg.show {level = 2, "Option", opt, "overridden by option", cause}
      end
      Options[opt] = nil
   end
end

-- test option passed as first parameter and set further options passed
local function opt_set_if (test_opt, ...)
   if test_opt then
      if Options[test_opt] then
	 for i, opt in ipairs ({...}) do
	    if not Options[opt] then
	       Msg.show {level = 2, "Option", opt, "added due to option", test_opt}
	       Options[opt] = true
	    end
	 end
      end
   end
end

-- test option passed as first parameter and clear further options passed
local function opt_clear_if (test_opt, ...)
   if test_opt then
      if Options[test_opt] then
	 for i, opt in ipairs ({...}) do
	    if Options[opt] then
	       Msg.show {level = 2, "Option", opt, "cleared due to option", test_opt}
	       Options[opt] = false
	    end
	 end
      end
   end
end

-- detect and fix incompatible options
local function opt_adjust ()
   opt_set_if ("jailed", "delay_installation")
   opt_set_if ("repo_mode", "jailed", "clean_packages")
   opt_set_if ("jailed", "packages", "packages_build")
   opt_clear_if ("repo_mode", "delay_installation")
   opt_clear_if	("repo_mode", "delay_installation")
--   opt_set_if	("default_yes", "delay_installation", "packages")
--   opt_set_if	("clean_packages_all, default_yes", "no_confirm")
   opt_set_if	("dry_run", "show_work")
   opt_clear_if	("interactive", "no_confirm")
end

-- ----------------------------------------------------------------------------------
-- options table indexed by longopt, values: shortopt, param_name, descr, action
-- - each command option has a long form
-- - use <nil> if no short options is defined
-- - use "$OPTARG" in the action to process the option argument
-- - opt_set (opt) sets the global variable "OPT[opt] to the optional 2nd argument or to the value true
-- - opt_clear (opt) unsets the global variable named "OPT[opt] with optional message regarding the cause
-- - ToDo: Verify that required parameters are actually provided!!!
VALID_OPTS = {
   all_old_abi		= { nil, nil,	"select all ports that have been built for a prior ABI version",	function (o, v) opt_set (o, v) end }, -- MAN
   all_options_change	= { nil, nil,	"select all ports for which new options have become available",		function (o, v) opt_set (o, v) end }, -- NYI
   backup_format	= { nil, "fmt",	"select backup package format",						function (o, v) set_package_format (o, v) end },
   check_depends	= { nil, nil,	"check and fix registered dependencies",				function (o, v) opt_set (o, v) end },
   check_port_dbdir	= { nil, nil,	"check for and delete stale port options",				function (o, v) opt_set (o, v) end },
   clean_packages	= { nil, nil,	"delete stale package files",						function (o, v) opt_set (o, v) end },
   clean_packages_all	= { nil, nil,	"delete stale package files without asking",				function (o, v) opt_set (o, v) end },
   clean_stale_libraries = { nil, nil,	"delete stale libraries",						function (o, v) opt_set (o, v) end },
   deinstall_unused	= { nil, nil,	"deinstall no longer required automatically installed packages",	function (o, v) opt_set (o, v) end },
   delay_installation	= { nil, nil,	"delay installation of ports unless they are build dependencies",	function (o, v) opt_set (o, v) end },
   delete_build_only	= { nil, nil,	"delete packages only used as build dependencies",			function (o, v) opt_set (o, v) end },
   force_config		= { nil, nil,	"ask for port options of each port",					function (o, v) opt_set (o, v) opt_clear ("no_make_config", o) end },
   jailed		= { nil, nil,	"build ports in a clean chroot jail",					function (o, v) opt_set (o, v) opt_set ("packages", "yes") opt_set ("create_package", "yes") end }, -- MAN
   list_origins		= { nil, nil,	"list origins of all installed ports",					function (o, v) opt_set (o, v) end },
   logfile		= { nil, "file", "log actions taken by portmaster to a file (NYI)",			function (o, v) opt_set (o, v) end }, -- NYI
   local_packagedir	= { nil, "dir",	"set local packages directory",						function (o, v) opt_set (o, v) end },
   no_confirm		= { nil, nil,	"do not ask for confirmation",						function (o, v) opt_set (o, v) opt_clear ("interactive", o) end },
   no_term_title	= { nil, nil,	"no progress indication in terminal title",				function (o, v) opt_set (o, v) end },
   package_format	= { nil, "fmt",	"select archive format of created packages",				function (o, v) set_package_format (o, v) end },
   packages_build	= { nil, nil,	"use packages to resolve build dependencies",				function (o, v) opt_set (o, v) end },
   repo_mode		= { nil, nil,	"update package repository",						function (o, v) opt_set (o, v) opt_set ("clean_packages", "yes") end },
   restart_with		= { nil, "filename", "restart aborted run with actions from named file",		function (o, v) restart_file_load (value) end }, -- MAN
   show_work		= { nil, nil,	"show progress",							function (o, v) opt_set (o, v) end },
   skip_recreate_pkg	= { nil, nil,	"do not overwrite existing package files",				function (o, v) opt_set (o, v) end },
   su_cmd		= { nil, "cmd",	"command and options that grant root privileges (e.g.: sudo)",		function (o, v) opt_set (o, v) end },
   try_broken		= { nil, nil,	"try to build ports marked as broken",					function (o, v) opt_set (o, v) end },
   no_backup		= { "B", nil,	"do not create backups of de-installed packages",			function (o, v) opt_clear ("backup", o) end },
   no_pre_clean		= { "C", nil,	"do not clean before building the ports",				function (o, v) opt_set (o, v) end },
   no_scrub_distfiles	= { "D", nil,	"do not delete stale distfiles",					function (o, v) opt_set (o, v) opt_clear ("scrub_distfiles", o) end },
   fetch_only		= { "F", nil,	"fetch only",								function (o, v) opt_set (o, v) end },
   no_make_config	= { "G", nil,	"do not configure ports",						function (o, v) opt_set (o, v) opt_clear ("force_config", o) end },
   hide_build		= { "H", nil,	"hide port build messages",						function (o, v) opt_set (o, v) end },
   no_post_clean	= { "K", nil,	"do not clean after building the ports",				function (o, v) opt_set (o, v) end },
   list_plus		= { "L", false,	"print verbose listing of installed ports",				function (o, v) opt_set ("list", "verbose") end },
   dry_run		= { "N", nil,	"print but do not actually execute commands",				function (o, v) opt_set (o, v) end },
   packages		= { "P", nil,	"use packages if available",						function (o, v) opt_set (o, v) end },
   restart		= { "R", false,	"restart build",							function (o, v) restart_file_load () end }, -- MAN
   version		= { "V", false,	"print program version",						function (o, v) print_version () end },
   all			= { "a", nil,	"operate on all installed ports",					function (o, v) opt_set (o, v) end },
   backup		= { "b", nil,	"create backups of de-installed packages",				function (o, v) opt_set (o, v) end },
   scrub_distfiles	= { "d", nil,	"delete stale distfiles",						function (o, v) opt_set (o, v) opt_clear ("no_scrub_distfiles", o) end },
-- expunge		= { "e", "package", "delete one port passed as argument and its distfiles",		function (o, v) opt_add (o, v) end },
   force		= { "f", nil,	"force action",								function (o, v) opt_set (o, v) end },
   create_package	= { "g", nil,	"create package files for all installed ports", 			function (o, v) opt_set (o, v) end },
   help			= { "h", false,	"show usage",								function (o, v) usage () end },
   interactive		= { "i", nil,	"interactive mode",							function (o, v) opt_set (o, v) end },
   list			= { "l", false,	"list installed ports",							function (o, v) opt_set ("list", "short") end },
   make_args		= { "m", "arg",	"pass option to make processes",					function (o, v) opt_add (o, v) end },
   default_no		= { "n", nil,	"assume answer 'no'",							function (o, v) opt_set (o, v) opt_clear ("default_yes", o) end },
   origin		= { "o", "origin",	"install from specified origin",				function (o, v) opt_set ("replace_origin", v) end },
   recursive		= { "r", "port", "force building of dependent ports",					function (o, v) ports_add_recursive (v, Options.replace_origin) opt_clear ("replace_origin") end },
   clean_stale		= { "s", nil,	"deinstall unused packages that were installed as dependency",		function (o, v) opt_set (o, v) opt_set ("thorough", "yes") end },
   thorough		= { "t", nil,	"check all dependencies and de_install unused automatic packages",	function (o, v) opt_set (o, v) end },
   verbose		= { "v", false,	"increase verbosity level",						function (o, v) Msg.level = Msg.level + 1 end },
   save_shared		= { "w", nil,	"keep backups of upgraded shared libraries",				function (o, v) opt_set (o, v) end },
   exclude		= { "x", "pattern", "add pattern to exclude list",					function (o, v) Excludes.add (v) end },
   default_yes		= { "y", nil,	"assume answer 'yes'",							function (o, v) opt_set (o, v) opt_clear ("default_no", o) end },
   developer_mode	= { nil, nil,	"create log and trace files",						function (o, v) tracefd = io.open (TRACEFILE, "w") end },
}

--
local function init ()
   local getopts_opts = ""
   local short_opt
   for k, v in pairs (VALID_OPTS) do
      short_opt = v[1]
      if short_opt then
	 LONGOPT[short_opt] = k
	 getopts_opts = getopts_opts .. short_opt
	 if v[2] then
	    getopts_opts = getopts_opts .. ":"
	 end
      end
   end
   getopts_opts = getopts_opts .. "-"

   -- Read a global rc file first
   rcfile_tryload ("/usr/local/etc/portmaster.rc")

   -- Read a local one next, and allow the command line to override later
   rcfile_tryload (os.getenv ("HOME") .. "/.portmasterrc")

      -- options processing
   local longopt_i = 0
   local current_i = 1
   for opt, opterr, i in P.getopt (arg, getopts_opts, opterr, i) do
      if opt == "-" then
	 opt = arg[current_i]:sub(3)
	 local value = opt:gsub(".+=(%S)", "%1")
	 opt = opt:gsub("=.*", "")
	 opt = opt:gsub("-", "_")
	 longopt_action (opt, value)
	 longopt_i = current_i
      elseif current_i > longopt_i then
	 if opt == "?" then
	    opt_err (arg[current_i]) -- does not return
	 else
	    local value
	    if i == current_i + 2 then
	       value = arg[i - 1]
	    end
	    shortopt_action (opt, value)
	 end
      end
      current_i = i
   end

   -- check for incompatible options and adjust them
   opt_adjust ()

   -- remove options before port and package glob arguments
   for i = 1, current_i - 1 do
      table.remove(arg, 1)
   end
end

-- translation table from old portmaster options to this version's options
OLD_RC_COMPAT = {
   ALWAYS_SCRUB_DISTFILES = "scrub_distfiles",
   DONT_POST_CLEAN = "no_post_clean",
   DONT_PRE_CLEAN = "no_pre_clean",
   DONT_SCRUB_DISTFILES = "no_scrub_distfiles",
   MAKE_PACKAGE = "create_package",
   PM_DEL_BUILD_ONLY = "verbose",
   PM_NO_MAKE_CONFIG = "no_make_config",
   PM_NO_CONFIRM = "no_confirm",
   PM_NO_TERM_TITLE = "no_term_title",
   PM_PACKAGES = "packages",
   PM_PACKAGES_NEWER = "packages",
   PM_PACKAGES_LOCAL = "packages",
   PM_PACKAGES_BUILD = "packages_build",
   PM_SU_CMD = "su_cmd",
   PM_VERBOSE = "verbose",
--   PM_ALWAYS_FETCH = "always_fetch",
--   PM_DELETE_PACKAGES = "deinstall_unused",
   RECURSE_THOROUGH = "thorough",
}

-- print program name and version
local function print_version ()
   Msg.show {start = true, PROGRAM, "version", VERSION}
end

-- convert option to rc file form (upper case and dash instead of underscore)
local function opt_name_rc (opt)
   opt = string.gsub (opt, "_", "-")
   return opt.lower
end

-- print rc file line to set option to "yes" or to "no" for all passed option names
local function opt_state_rc (...)
   local opts = {...}
   local result = ""
   for i = 1, #opts do
      local opt = opts[i]
      if Options[opt] then
	 result = result .. opt .. "=yes\n"
      else
	 result = result .. opt .. "=no\n"
      end
   end
   return result
end

-- print rc file lines with the values of all passed option names
local function opt_value_rc (...)
   local opts = {...}, opt
   local result = ""
   for i = 1, #opts do
      opt = opts[i]
      local val = Options[opt]
      if val then
	 local type = type (val)
	 if type == "string" then
	    result = result .. opt .. "=" .. val .. "\n"
	 elseif type == "table" then
	    for i, val in ipairs (val) do
	       result = result .. opt .. "=" .. val .. "\n"
	    end
	 end
      end
   end
   return result
end

-- name of restart file dependent on tty name or pid
local function restart_file_name ()
   local id
   -- use name of STDOUT device if connected to a tty, else PID
   local tty = ttyname ()
   if tty then
      tty = string.gsub (tty, "/dev/", "")
      id = string.gsub (tty, "/", "_")
   else
      id = "pid_" .. getpid() -- $PID
   end
   return "/tmp/pm.restart." .. id .. ".rc"
end

-- print upgrade specifier line
local function restart_file_print_upgrade (build_type, origin_new)
   local origin_old, pkgname_old, pkgname_new, pkgfile, special_depends
   pkgname_new = PKGNAME_NEW[origin_new]
   if build_type == "pkg" then
      special_depends = nil
      pkgfile = nil
   else
      origin_old = ORIGIN_OLD[origin_new]
      pkgname_old = PKGNAME_OLD[origin_new]
      special_depends = SPECIAL_DEPENDS[origin_new]
      pkgfile = USEPACKAGE[origin_new] or "-" -- DEBUGGING ONLY - COMPATIBILITY WITH SHELL VERSION
   end
   if special_depends and not pkgfile then
      pkgfile = "-"
   end
   local line
   if pkgname_old then
      origin_old = origin_old or origin_new
   else
      origin_old = {name = "-"}
      pkgname_old = "-"
   end
   line = table.concat ({"#: Upgrade_" .. build_type, origin_old, origin_new, pkgname_old, pkgname_new}, " ")
   if pkgfile then
      line = line .. " " .. pkgfile
   end
   if special_depends then
      line = line .. " " .. table.concat (spcial_depends, " ")
   end
   return line .. "\n"
end
   
-- print "delete after" line
local function restart_file_print_delafter (cond, origin_new)
   local last_use = {}
   if cond == "build" then
      last_use = DEP_DEL_AFTER_BUILD[origin_new]
   else
      last_use = DEP_DEL_AFTER_RUN[origin_new]
   end
   --[[
   if last_use then
      for i, origin in ipairs (last_use) do
	 return "#: Purge_after_" .. cond .. " - " .. origin_new .. " - - - " .. origin .. "\n"
      end
   end
   --]]
   if last_use then
      return "#: Purge_after_" .. cond .. " - " .. origin_new .. " - - - " .. table.concat (last_use, " ") .. "\n"
   end
end

-- write all outstanding tasks to a file to allow to resume after an error
local function save ()
   local tmpf

   local function w (format, ...)
      tmpf:write (string.format (format .. "\n", ...))
      --print (string.format (format, ...))
   end

   if PHASE == "" then
      return
   end
   local tasks = tasks_count ()
   if tasks == 0 then
      return
   end
   -- trap "" INT -- NYI
   Msg.show {start = true}
   Msg.show {"Writing restart file for", tasks, "actions ..."}

   local tmp_filename = tempfile_create ("RESTART")
   tmpf = io.open (tmp_filename, "w+")

   if PHASE == "scan" then
      for k, v in ipairs (Excludes.list()) do
	 w ("EXCLUDE=%s", v)
      end
   else
      Options.all = nil
      Options.all_old_abi = nil
      Options.all_options_change = nil
   end

   local opts = table.keys (VALID_OPTS)
   table.sort (opts)
   for i, k in ipairs (opts) do
      local t = VALID_OPTS[k]
      local takes_arg = t[2] -- parameter name as string, nil if none, false to skip
      if takes_arg ~= false then
	 if takes_arg then
	    tmpf:write (opt_value_rc (k))
	 else
	    tmpf:write (opt_state_rc (k))
	 end
      end
   end

   for i = 1, Msg.level do
      tmpf:write ("verbose=yes\n")
   end
   w ("")
   --[[
   for i, pkgname_old in ipairs (DELETES) do
      w ("#: Delete - - %s", pkgname_old)
   end
   for i, origin_new in ipairs (MOVES) do
      w ("#: Move %s %s %s", ORIGIN_OLD[origin_new], origin_new, PKGNAME_OLD[origin_new])
   end
   for i, origin_new in ipairs (PKG_RENAMES) do
      w ("#: Rename - %s %s %s", origin_new, PKGNAME_OLD[origin_new], PKGNAME_NEW[origin_new])
   end
   for i, origin_new in ipairs (WORKLIST) do
      if BUILDDEP[origin_new] then
	 tmpf:write (restart_file_print_upgrade ("build", origin_new))
      end
      tmpf:write (restart_file_print_delafter ("build", origin_new))
      if RUNDEP[origin_new] then
	 tmpf:write (restart_file_print_upgrade ("run", origin_new))
      end
      tmpf:write (restart_file_print_delafter ("del", origin_new))
   end
   PHASE = "install"
   for i, origin_new in ipairs (DELAYED_INSTALL_LIST) do
      tmpf:write (restart_file_print_upgrade ("pkg", origin_new))
   end
   --]]

   filename = restart_file_name ()
   os.remove (filename)
   os.rename (tmp_filename, filename)
   Msg.show {"Restart information has been written to", filename}
end

-- register upgrade in the restart case where no dependency checks have been performed
local function register_upgrade_restart (dep_type, origin_old, origin_new, pkgname_old, pkgname_new, pkgfile, ...)
   if origin_old == "-" then
      if pkgname_old == "-" then
	 pkgname_old = nil
	 origin_old = nil
      else
	 origin_old = origin_new
      end
   end
   if pkgfile == "-" then
      pkgfile = nil
   end
   --
   if origin_old ~= origin_new then
      ORIGIN_OLD[origin_new] = origin_old
   end
   if pkgname_old then
      PKGNAME_OLD[origin_new] = pkgname_old
   end
   if pkgname_new then
      PKGNAME_NEW[origin_new] = pkgname_new
   end
   if pkgfile then
      USEPACKAGE[origin_new] = pkgfile
   end
   local special_depends = {...}
   if special_depends[1] then
      SPECIAL_DEPENDS[origin_new] = special_depends
   end
   --
   if dep_type == "pkg" then
      delayedlist_add (origin_new)
   else
      worklist_add (origin_new)
      if dep_type == "build" then
	 BUILDDEP[origin_new] = true
      elseif dep_type == "run" then
	 RUNDEP[origin_new] = true
      end
      if not UPGRADES[origin_new] then
	 UPGRADES[origin_new] = true
	 if not pkgfile and not Options.dry_run then
	    distfiles_fetch (origin_new)
	 end
      end
   end
end
       
-- parse action line of restart file and register action
local function restart_file_parse_line (hash, command, origin_old, origin_new, pkgname_old, pkgname_new, pkgfile, ...)
   local special_depends = {...}
   if hash == "#:" and not check_locked (pkgname_old) and not excludes_check (pkgname_new, origin_new) then
      if command == "Delete" then
	 register_delete (pkgname_old)
      elseif command == "Move" then
	 register_moved (origin_old, origin_new, pkgname_old)
      elseif command == "Rename" then
	 register_pkgname_chg (origin_new, pkgname_old, pkgname_new)
      elseif command == "Install_build" then
	 register_upgrade_restart ("build", "", origin_new, "", pkgname_new, pkgfile, special_depends)
      elseif command == "Install_run" then
	 register_upgrade_restart ("run", "", origin_new, "", pkgname_new, pkgfile, special_depends)
      elseif command == "Upgrade_build" then
	 register_upgrade_restart ("build", origin_old, origin_new, pkgname_old, pkgname_new, pkgfile, special_depends)
      elseif command == "Upgrade_run" then
	 register_upgrade_restart ("run", origin_old, origin_new, pkgname_old, pkgname_new, pkgfile, special_depends)
      elseif command == "Purge_after_build" then
	 DEP_DEL_AFTER_BUILD[origin_new] = special_depends
      elseif command == "Purge_after_del" then
	 DEP_DEL_AFTER_RUN[origin_new] = special_depends
      else
	 return false
      end
   end
   return true
end

-- load options and actions from restart file
local function restart_file_load (filename)
   filename = filename or restart_file_name ()
   -- assert restart file exists with length > 0
   assert (access (filename, "r"), "cannot read restart file " .. filename)
   Msg.show {"Loading restart information from file", filename, "..."}
   rcfile_tryload (filename)
   local rcfile = io.open (filename, "r")
   for line in rcfile:lines() do
      if #line > 0 then
	 assert (restart_file_parse_line (line), "illegal line in restart file: " .. line)
      end
   end
   if not Options.dry_run then
      os.remove (filename)
   end
end

Options.init = init
Options.save = save

return Options
