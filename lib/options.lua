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
local Excludes = require("portmaster.excludes")
local Msg = require("portmaster.msg")
local Param = require("portmaster.param")
local Trace = require("portmaster.trace")

-------------------------------------------------------------------------------
local TRACE = Trace.trace

-------------------------------------------------------------------------------------
local P = require "posix"
local getopt = P.getopt

local P_US = require("posix.unistd")
local ttyname = P_US.ttyname

-------------------------------------------------------------------------------------
local PROGRAM = arg[0]:gsub(".*/", "")
local VERSION = "4.0.0a1" -- GLOBAL

-------------------------------------------------------------------------------------
-- options and rc file processing
local Options = {}
local LONGOPT = {}
local VALID_OPTS = {}

-- print the long options ordered by associated short option followed by sorted list of longopts without short option
local function print_longopts()
    local result = {}
    local longopts = table.keys(LONGOPT)
    table.sort(longopts)
    for _, v in ipairs(longopts) do
        table.insert(result, LONGOPT[v])
    end
    longopts = table.keys(VALID_OPTS)
    table.sort(longopts)
    for _, v in ipairs(longopts) do
        if VALID_OPTS[v].letter == nil then
            table.insert(result, v)
        end
    end
    return result
end

-- print version and usage message
local function usage()
    -- print_version ()
    -- print ()
    io.stderr:write("Usage: ", PROGRAM, " [option ...] [portorigin|packagename] ...\n")
    io.stderr:write("\n")
    io.stderr:write("Options:\n")
    local options_descr = {}
    local maxlen = 0
    for _, longopt in pairs(print_longopts()) do
        local line = ""
        local spec = VALID_OPTS[longopt]
        local shortopt = spec.letter
        local param = spec.param
        local descr = spec.descr
        if shortopt then
            line = "-" .. shortopt
            if param then
                line = line .. " <" .. param .. ">"
            end
            line = line .. " | "
        end
        line = line .. "--" .. longopt:gsub("_", "-")
        if param then
            line = line .. "=<" .. param .. ">"
        end
        table.insert(options_descr, {line, descr})
        if #line > maxlen then
            maxlen = #line
        end
    end
    local fmt = " %-" .. maxlen + 1 .. "s %s\n"
    for _, v in ipairs(options_descr) do
        io.stderr:write(string.format(fmt, v[1], v[2]))
    end
    os.exit(2)
end

--
local function opt_err(opt)
    io.stderr:write("Unknown option '" .. opt .. "'\n\n")
    usage()
end

--
local function opt_check(opt)
    if VALID_OPTS[opt] then
        return opt
    elseif opt then
        opt = LONGOPT[opt]
        if opt then
            return opt
        end
    end
    error("Invalid option " .. (opt or "<nil>"), 2)
end

-- process long option of type "--longopt=param" with optional param
local function longopt_action(opt, arg)
    --TRACE("LONGOPT_ACTION", opt, arg)
    local opt_rec = VALID_OPTS[opt]
    if not opt_rec then
        opt_err(opt)
    end
    local param = opt_rec.param
    if param then
        assert(arg and #arg > 0, "required parameter is missing")
    else
        -- assert (not arg or #arg == 0, "parameter '" .. arg .. "' is unexpected")
        if arg == "no" then
            arg = nil
        else
            arg = opt
        end
    end
    opt_rec.func(opt, arg)
end

-- process short option of type "-o param" with optional param
local function shortopt_action(opt, arg)
    local longopt = LONGOPT[opt]
    if not longopt then
        opt_err(opt)
    end
    longopt_action(longopt, arg)
end

-- translation table from old portmaster options to this version's options
local OLD_RC_COMPAT = {
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

--
local function rcfile_tryload(filename)
    local inp = io.open(filename, "r")
    --TRACE("RCFILE_TRYLOAD", filename, inp)
    if not inp then
        return
    end
    local lineno = 0
    for line in inp:lines("*l") do
        lineno = lineno + 1
        line = line:gsub("#.*", "")
        if #line > 0 then
            local opt, value = string.match(line, "([^#%s]+)%s*=%s*(%S*)")
            if opt then
                if OLD_RC_COMPAT[opt] then
                    opt = OLD_RC_COMPAT[opt]
                elseif strpfx(opt, "PM_") then
                    error("unsupported old option")
                else
                    opt = string.lower(opt:gsub("-", "_"))
                    opt = opt_check(opt)
                    assert(opt)
                end
                value = value or "no"
                if string.lower(value) == "no" then
                    value = "no"
                end
                longopt_action(opt, value)
            end
        end
    end
end

-- set package format option with check for supported values
local VALID_FORMATS = {
    tar = true,
    tgz = true,
    tbz = true,
    txz = true,
    zstd = true,
    bsd = true,
}

local function set_package_format(var, fmt)
    assert(VALID_FORMATS[fmt], "invalid package format '" .. fmt .. "'")
    Param[var] = fmt
end

-- set option (or clear, if value is nil)
local function opt_set(opt, value)
    --TRACE("OPT_SET", opt, value)
    Options[opt] = value
end

-- set option (or clear, if value is nil)
local function opt_incr(opt, value)
    local v = rawget(Options, opt) or 0
    Options[opt] = v + 1
end

-- append passed value to option string
local function opt_add(opt, value)
    local t = Options[opt] or {}
    table.insert(t, value)
    Options[opt] = t
end

-- clear passed option, with message if cause is provided
local function opt_clear(opt, cause)
    if Options[opt] then
        if cause then
            Msg.show {level = 2, "Option", opt, "overridden by option", cause}
        end
        Options[opt] = nil
    end
end

-- test option passed as first parameter and set further options passed
local function opt_set_if(test_opt, ...)
    if test_opt then
        if Options[test_opt] then
            for _, opt in ipairs({...}) do
                if not Options[opt] then
                    Msg.show {level = 2, "Option", opt, "added due to option", test_opt}
                    opt_set(opt, true)
                end
            end
        end
    end
end

-- test option passed as first parameter and clear further options passed
local function opt_clear_if(test_opt, ...)
    if test_opt then
        if Options[test_opt] then
            for _, opt in ipairs({...}) do
                if Options[opt] then
                    opt_clear(opt, test_opt)
                end
            end
        end
    end
end

-- detect and fix incompatible options
local function opt_adjust()
    opt_set_if("jailed", "delay_installation")
    opt_set_if("repo_mode", "jailed", "clean_packages")
    opt_set_if("jailed", "packages", "packages_build")
    opt_clear_if("repo_mode", "delay_installation")
    opt_clear_if("repo_mode", "delay_installation")
    --   opt_set_if	("default_yes", "delay_installation", "packages")
    --   opt_set_if	("clean_packages_all, default_yes", "no_confirm")
    opt_set_if("dry_run", "show_work")
    opt_clear_if("interactive", "no_confirm")
    if Msg.level() > 2 then
        opt_set("show_work", true)
    end
end

-------------------------------------------------------------------------------------
-- options table indexed by longopt, values: shortopt, param_name, descr, action
-- - each command option has a long form
-- - use <nil> if no short options is defined
-- - use "$OPTARG" in the action to process the option argument
-- - opt_set (opt) sets the global variable "OPT[opt] to the optional 2nd argument or to the value true
-- - opt_clear (opt) unsets the global variable named "OPT[opt] with optional message regarding the cause
-- - ToDo: Verify that required parameters are actually provided!!!
VALID_OPTS = {
    all_old_abi = {
        descr = "select all ports that have been built for a prior ABI version",
        func = function(o, v)
            opt_set(o, v)
        end,
    }, -- MAN
    all_options_change = {
        descr = "select all ports for which new options have become available",
        func = function(o, v)
            opt_set(o, v)
        end,
    }, -- NYI
    backup_format = {
        param = "fmt",
        descr = "select backup package format",
        func = function(o, v)
            set_package_format(o, v)
        end,
    },
    check_depends = {
        descr = "check and fix registered dependencies",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    check_port_dbdir = {
        descr = "check for and delete stale port options",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    clean_packages = {
        descr = "delete stale package files",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    clean_packages_all = {
        descr = "delete stale package files without asking",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    clean_stale_libraries = {
        descr = "delete stale libraries",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    deinstall_unused = {
        descr = "deinstall no longer required automatically installed packages",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    delay_installation = {
        descr = "delay installation of ports unless they are build dependencies",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    delete_build_only = {
        descr = "delete packages only used as build dependencies",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    force_config = {
        descr = "ask for port options of each port",
        func = function(o, v)
            opt_set(o, v)
            opt_clear("no_make_config", o)
        end,
    },
    jailed = {
        descr = "build ports in a clean chroot jail",
        func = function(o, v)
            opt_set(o, v)
            opt_set("packages", "yes")
            opt_set("create_package", "yes")
        end,
    }, -- MAN
    list_origins = {
        descr = "list origins of all installed ports",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    logfile = {
        param = "file",
        descr = "log actions taken by portmaster to a file (NYI)",
        func = function(o, v)
            opt_set(o, v)
        end,
    }, -- NYI
    local_packagedir = {
        param = "dir",
        descr = "set local packages directory",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    no_confirm = {
        descr = "do not ask for confirmation",
        func = function(o, v)
            opt_set(o, v)
            opt_clear("interactive", o)
        end,
    },
    no_term_title = {
        descr = "no progress indication in terminal title",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    package_format = {
        param = "fmt",
        descr = "select archive format of created packages",
        func = function(o, v)
            set_package_format(o, v)
        end,
    },
    packages_build = {
        descr = "use packages to resolve build dependencies",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    repo_mode = {
        descr = "update package repository",
        func = function(o, v)
            opt_set(o, v)
            opt_set("clean_packages", "yes")
        end,
    },
    restart_with = {
        param = "filename",
        descr = "restart aborted run with actions from named file",
        func = function(o, v)
            restart_file_load(v)
        end,
    }, -- MAN
    show_work = {
        descr = "show progress",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    skip_recreate_pkg = {
        descr = "do not overwrite existing package files",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    su_cmd = {
        param = "cmd",
        descr = "command and options that grant root privileges (e.g.: sudo)",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    try_broken = {
        descr = "try to build ports marked as broken",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    no_backup = {
        letter = "B",
        descr = "do not create backups of de-installed packages",
        func = function(o, v)
            opt_clear("backup", o)
        end,
    },
    no_pre_clean = {
        letter = "C",
        descr = "do not clean before building the ports",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    no_scrub_distfiles = {
        letter = "D",
        descr = "do not delete stale distfiles",
        func = function(o, v)
            opt_set(o, v)
            opt_clear("scrub_distfiles", o)
        end,
    },
    fetch_only = {
        letter = "F",
        descr = "fetch only",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    no_make_config = {
        letter = "G",
        descr = "do not configure ports",
        func = function(o, v)
            opt_set(o, v)
            opt_clear("force_config", o)
        end,
    },
    hide_build = {
        letter = "H",
        descr = "hide port build messages",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    no_post_clean = {
        letter = "K",
        descr = "do not clean after building the ports",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    list_plus = {
        letter = "L",
        param = false,
        descr = "print verbose listing of installed ports",
        func = function(o, v)
            opt_set("list", "verbose")
        end,
    },
    dry_run = {
        letter = "N",
        descr = "print but do not actually execute commands",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    packages = {
        letter = "P",
        descr = "use packages if available",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    restart = {
        letter = "R",
        param = false,
        descr = "restart build",
        func = function(o, v)
            restart_file_load()
        end,
    }, -- MAN
    version = {
        letter = "V",
        param = false,
        descr = "print program version",
        func = function(o, v)
            print_version()
        end,
    },
    developer_mode = {
        letter = "Z",
        descr = "create log and trace files",
        func = function(o, v)
            opt_set(o,v)
        end
    },
    all = {
        letter = "a",
        descr = "operate on all installed ports",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    backup = {
        letter = "b",
        descr = "create backups of de-installed packages",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    scrub_distfiles = {
        letter = "d",
        descr = "delete stale distfiles",
        func = function(o, v)
            opt_set(o, v)
            opt_clear("no_scrub_distfiles", o)
        end,
    },
    --[[
     expunge = {
        letter = "e",
        param = "package",
        descr = "delete one port passed as argument and its distfiles",
        func = function (o, v)
            opt_add (o, v)
        end
    },
    --]]
    force = {
        letter = "f",
        descr = "force action",
        func = function(o, v)
            opt_incr(o, v)
        end,
    },
    create_package = {
        letter = "g",
        descr = "create package files for all installed ports",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    help = {
        letter = "h",
        param = false,
        descr = "show usage",
        func = function(o, v)
            usage()
        end,
    },
    interactive = {
        letter = "i",
        descr = "interactive mode",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    list = {
        letter = "l",
        param = false,
        descr = "list installed ports",
        func = function(o, v)
            opt_set("list", "short")
        end,
    },
    make_args = {
        letter = "m",
        param = "arg",
        descr = "pass option to make processes",
        func = function(o, v)
            opt_add(o, v)
        end,
    },
    default_no = {
        letter = "n",
        descr = "assume answer 'no'",
        func = function(o, v)
            opt_set(o, v)
            opt_clear("default_yes", o)
        end,
    },
    origin = {
        letter = "o",
        param = "origin",
        descr = "install from specified origin",
        func = function(o, v)
            opt_set("replace_origin", v)
        end,
    }, -- use module local static variable to hold this value ???
    recursive = {
        letter = "r",
        param = "port",
        descr = "force building of dependent ports",
        func = function(o, v)
            ports_add_recursive(v, Options.replace_origin)
            opt_clear("replace_origin")
        end,
    },
    clean_stale = {
        letter = "s",
        descr = "deinstall unused packages that were installed as dependency",
        func = function(o, v)
            opt_set(o, v)
            opt_set("thorough", "yes")
        end,
    },
    thorough = {
        letter = "t",
        descr = "check all dependencies and de-install unused automatic packages",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    verbose = {
        letter = "v",
        param = false,
        descr = "increase verbosity level",
        func = function(o, v)
            Msg.incr_level()
        end,
    },
    save_shared = {
        letter = "w",
        descr = "keep backup copies of replaced shared libraries",
        func = function(o, v)
            opt_set(o, v)
        end,
    },
    exclude = {
        letter = "x",
        param = "pattern",
        descr = "add pattern to exclude list",
        func = function(o, v)
            Excludes.add(v)
        end,
    },
    default_yes = {
        letter = "y",
        descr = "assume answer 'yes'",
        func = function(o, v)
            opt_set(o, v)
            opt_clear("default_no", o)
        end,
    },
}

--
local function init()
    local getopts_opts = ""
    for k, v in pairs(VALID_OPTS) do
        local short_opt = v.letter
        if short_opt then
            LONGOPT[short_opt] = k
            getopts_opts = getopts_opts .. short_opt
            if v.param then
                getopts_opts = getopts_opts .. ":"
            end
        end
    end
    getopts_opts = getopts_opts .. "-"

    -- Read a global rc file first
    rcfile_tryload("/usr/local/etc/portmaster.rc")

    -- Read a local one next, and allow the command line to override later
    rcfile_tryload(path_concat(Param.home, "/.portmasterrc"))

    -- options processing
    local longopt_i = 0
    local current_i = 1
    local opterr
    local i
    for opt, opterr, i in getopt(arg, getopts_opts, opterr, i) do -- check getopt usage parameters 3 and 4
        if opt == "-" then
            opt = arg[current_i]:sub(3)
            local value = opt:gsub(".+=(%S)", "%1")
            opt = opt:gsub("=.*", "")
            opt = opt:gsub("-", "_")
            longopt_action(opt, value)
            longopt_i = current_i
        elseif current_i > longopt_i then
            if opt == "?" then
                opt_err(arg[current_i]) -- does not return
            else
                local value
                if i == current_i + 2 then
                    value = arg[i - 1]
                end
                shortopt_action(opt, value)
            end
        end
        current_i = i
    end

    -- do not ask for confirmation if not connected to a terminal
    if not ttyname(0) then
        local tty = io.open("/dev/tty", "r")
        if not tty then
            Options.no_confirm = true
        end
    end

    -- disable setting the terminal title if output goes to a pipe or file
    if not ttyname(2) then
        Options.no_term_title = true
    end

    -- check for incompatible options and adjust them
    opt_adjust()

    -- export reference to Options table into Msg module
    Msg.copy_options(Options)

    -- remove options before port and package glob arguments
    return {table.unpack(arg, current_i)}
end

-- print program name and version
local function print_version()
    Msg.show {start = true, PROGRAM, "version", VERSION}
end

-- print rc file line to set option to "yes" or to "no" for all passed option names
local function opt_state_rc(...)
    local opts = {...}
    local result = {}
    for i = 1, #opts do
        local opt = opts[i]
        if Options[opt] then
            table.insert(result, opt .. "=yes")
        else
            table.insert(result, opt .. "=no")
        end
    end
    table.insert(result, "")
    return table.concat(result, "\n")
end

-- print rc file lines with the values of all passed option names
local function opt_value_rc(...)
    local opts = {...}
    local result = {}
    for i = 1, #opts do
        local opt = opts[i]
        local val = Options[opt]
        if val then
            local type = type(val)
            if type == "string" then
                table.insert(result, opt .. "=" .. val)
            elseif type == "table" then
                for _, val in ipairs(val) do
                    table.insert(result, opt .. "=" .. val)
                end
            end
        end
    end
    table.insert(result, "")
    return table.concat(result, "\n")
end

--[[
-- name of restart file dependent on tty name or pid
local function restart_file_name()
    local id
    -- use name of STDOUT device if connected to a tty, else PID
    local tty = ttyname()
    if tty then
        tty = string.gsub(tty, "/dev/", "")
        id = string.gsub(tty, "/", "_")
    else
        id = "pid_" .. getpid() -- $PID
    end
    return "/tmp/pm.restart." .. id .. ".rc"
end

-- write all outstanding tasks to a file to allow to resume after an error
local function save()
    local tmpf
do return end
    local function w(format, ...)
        tmpf:write(string.format(format .. "\n", ...))
        -- print (string.format (format, ...))
    end

    if Param.phase == "" then
        return
    end
    local tasks = tasks_count()
    if tasks == 0 then
        return
    end
    -- trap "" INT -- NYI
    Msg.show {start = true}
    Msg.show {"Writing restart file for", tasks, "actions ..."}

    local tmp_filename = tempfile_create("RESTART")
    tmpf = io.open(tmp_filename, "w+")

    if Param.phase == "scan" then
        for _, v in ipairs(Excludes.list()) do
            w("EXCLUDE=%s", v)
        end
    else
        Options.all = nil
        Options.all_old_abi = nil
        Options.all_options_change = nil
    end

    local opts = table.keys(VALID_OPTS)
    table.sort(opts)
    for _, k in ipairs(opts) do
        local t = VALID_OPTS[k]
        local takes_arg = t[2] -- parameter name as string, nil if none, false to skip
        if takes_arg ~= false then
            if takes_arg then
                tmpf:write(opt_value_rc(k))
            else
                tmpf:write(opt_state_rc(k))
            end
        end
    end

    for _ = 1, Msg.level() do
        tmpf:write("verbose=yes\n")
    end
    w("")

    local filename = restart_file_name()
    os.remove(filename)
    os.rename(tmp_filename, filename)
    Msg.show {"Restart information has been written to", filename}
end

-- register upgrade in the restart case where no dependency checks have been performed
local function register_upgrade_restart(dep_type, o_o, o_n,
                                        pkgname_old, pkgname_new, pkgfile, ...)
    if o_o == "-" then
        if pkgname_old == "-" then
            pkgname_old = nil
            o_o = nil
        else
            o_o = o_n
        end
    end
    if pkgfile == "-" then pkgfile = nil end
    --
    if o_o ~= o_n then o_o[o_n] = o_o end
    if pkgname_old then PKGNAME_OLD[o_n] = pkgname_old end
    if pkgname_new then PKGNAME_NEW[o_n] = pkgname_new end
    if pkgfile then USEPACKAGE[o_n] = pkgfile end
    local special_depends = {...}
    if special_depends[1] then SPECIAL_DEPENDS[o_n] = special_depends end
    --
    if dep_type == "pkg" then
        delayedlist_add(o_n)
    else
        worklist_add(o_n)
        if dep_type == "build" then
            BUILDDEP[o_n] = true
        elseif dep_type == "run" then
            RUNDEP[o_n] = true
        end
        if not UPGRADES[o_n] then
            UPGRADES[o_n] = true
            if not pkgfile and not Options.dry_run then
                distfiles_fetch(o_n)
            end
        end
    end
end

-- parse action line of restart file and register action
local function restart_file_parse_line(hash, command, o_o, o_n,
                                       pkgname_old, pkgname_new, pkgfile, ...)
    local special_depends = {...}
    if hash == "#:" and not check_locked(pkgname_old) and
        not Excludes.check(pkgname_new, o_n) then
        if command == "Delete" then
            register_delete(pkgname_old)
        elseif command == "Move" then
            register_moved(o_o, o_n, pkgname_old)
        elseif command == "Rename" then
            register_pkgname_chg(o_n, pkgname_old, pkgname_new)
        elseif command == "Install_build" then
            register_upgrade_restart("build", "", o_n, "", pkgname_new,
                                     pkgfile, special_depends)
        elseif command == "Install_run" then
            register_upgrade_restart("run", "", o_n, "", pkgname_new,
                                     pkgfile, special_depends)
        elseif command == "Upgrade_build" then
            register_upgrade_restart("build", o_o, o_n,
                                     pkgname_old, pkgname_new, pkgfile,
                                     special_depends)
        elseif command == "Upgrade_run" then
            register_upgrade_restart("run", o_o, o_n, pkgname_old,
                                     pkgname_new, pkgfile, special_depends)
        elseif command == "Purge_after_build" then
            DEP_DEL_AFTER_BUILD[o_n] = special_depends
        elseif command == "Purge_after_del" then
            DEP_DEL_AFTER_RUN[o_n] = special_depends
        else
            return false
        end
    end
    return true
end

-- load options and actions from restart file
local function restart_file_load(filename)
    filename = filename or restart_file_name()
    -- assert restart file exists with length > 0
    assert(access(filename, "r"), "cannot read restart file " .. filename)
    Msg.show {"Loading restart information from file", filename, "..."}
    rcfile_tryload(filename)
    local rcfile = io.open(filename, "r")
    for line in rcfile:lines() do
        if #line > 0 then
            assert(restart_file_parse_line(line),
                   "illegal line in restart file: " .. line)
        end
    end
    if not Options.dry_run then os.remove(filename) end
end
--]]

Options.init = init
-- Options.save = save
-- Options.restart_file_load = restart_file_load

return Options
