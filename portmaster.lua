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

-------------------------------------------------------------------------------------
--local dbg = require("debugger")

local P = require("posix")
local glob = P.glob

local P_PW = require("posix.pwd")
local getpwuid = P_PW.getpwuid

local P_SL = require("posix.stdlib")
local setenv = P_SL.setenv

local P_SS = require("posix.sys.stat")
local stat = P_SS.stat
local lstat = P_SS.lstat
local stat_isdir = P_SS.S_ISDIR
-- local stat_isreg = P_SS.S_ISREG

local P_US = require("posix.unistd")
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

R = require("std.strict")

-- local _debug = require 'std._debug'(true)

Package = require("portmaster.package")
Origin = require("portmaster.origin")
local Options = require("portmaster.options")
local Msg = require("portmaster.msg")
local Progress = require("portmaster.progress")
local Distfile = require("portmaster.distfiles")
local Action = require("portmaster.action")
local Exec = require("portmaster.exec")
local PkgDb = require("portmaster.pkgdb")
local Strategy = require("portmaster.strategy")

-------------------------------------------------------------------------------------
stdin = io.stdin
tracefd = nil

-------------------------------------------------------------------------------------
setenv("PID", getpid())
setenv("LANG", "C")
setenv("LC_CTYPE", "C")
setenv("CASE_SENSITIVE_MATCH", "yes")
setenv("LOCK_RETRIES", "120")
-- setenv ("WRKDIRPREFIX", "/usr/work") -- ports_var ???

-------------------------------------------------------------------------------------
-- clean up when script execution ends
local function exit_cleanup(exit_code)
    exit_code = exit_code or 0
    Progress.clear()
    Distfile.fetch_finish()
    tempfile_delete("FETCH_ACK")
    tempfile_delete("BUILD_LOG")
    Options.save()
    Msg.success_show()
    if tracefd then
        io.close(tracefd)
    end
    os.exit(exit_code)
    -- not reached
end

-- abort script execution with an error message
function fail(...)
    Msg.show {start = true, "ERROR:", ...}
    -- Msg.show {"Fix the issue and use '" .. PROGRAM, "-R' to restart"}
    Msg.show {"Aborting update"}
    exit_cleanup(1)
    -- not reached
end

--
local STARTTIMESECS = os.time()
local tracefd

function TRACE(...)
    if tracefd then
        local sep = ""
        local tracemsg = ""
        local t = {...}
        for i = 1, #t do
            local v = t[i] or ("<" .. tostring(t[i]) .. ">")
            v = tostring(v)
            if v == "" or string.find(v, " ") then
                v = "'" .. v .. "'"
            end
            tracemsg = tracemsg .. sep .. v
            sep = " "
        end
        local dbginfo = debug.getinfo(3, "Sl") or debug.getinfo(2, "Sl")
        tracefd:write(tostring(os.time() - STARTTIMESECS) .. "	" .. (dbginfo.short_src or "(main)") .. ":" ..
                          dbginfo.currentline .. "\t" .. tracemsg .. "\n")
    end
end

-- abort script execution with an internal error message on unexpected error
function fail_bug(...)
    Msg.show {"INTERNAL ERROR:", ...}
    Msg.show {"Aborting update"}
    exit_cleanup(10)
    -- not reached
end

-- remove trailing new-line, if any (UTIL) -- unused ???
function chomp(str)
    if str and str:byte(-1) == 10 then
        return str:sub(1, -2)
    end
    return str
end

-------------------------------------------------------------------------------------
-- split string on word boundaries and return as table
function split_words(str)
    if str then
        local result = {}
        for word in string.gmatch(str, "%S+") do
            table.insert(result, word)
        end
        return result
    end
end

-- split string on line boundaries and return as table
function split_lines(str)
    local result = {}
    for line in string.gmatch(str, "([^\n]*)\n?") do
        table.insert(result, line)
    end
    return result
end

-- split line at blanks into parts at most columns long and return as table
function split_at(line, columns)
    local result = {}
    while #line > columns do
        local l0 = string.sub(line, 1, columns)
        local l1, l2 = string.match(l0, "([%S ]+) (.*)")
        line = l2 .. string.sub(line, columns + 1)
        table.insert(result, l1)
    end
    if #line > 0 then
        table.insert(result, line)
    end
    return result
end

--
function set_str(self, field, v)
    self[field] = v ~= "" and v or false
end

--
function set_bool(self, field, v)
    self[field] = (v and v ~= "" and v ~= "0") and true or false
end

--
function set_table(self, field, v)
    self[field] = v ~= "" and split_words(v) or false
end

------------------------------------------------------------------------------------- (UTIL)
-- test whether the second parameter is a prefix of the first parameter (UTIL)
function strpfx(str, pattern)
    return str:sub(1, #pattern) == pattern
end

-- return flavor part of origin with flavor if present
function flavor_part(origin)
    return (string.match(origin, "%S+@([^:]+)"))
end

-- remove flavor part of origin to obtain a file system path
function dir_part(origin)
    return (string.match(origin, "^[^:@]+"))
end

-- optional make target component of port dependency or "install" if none
function target_part(dep)
    local target = string.match(dep, "%S+:(%a+)")
    return target or "install"
end

-------------------------------------------------------------------------------------
-- local table_mt = getmetatable(table)

-- return list of all keys of a table -- UTIL
function table:keys()
    local result = {}
    for k, _ in pairs(self) do
        if type(k) ~= "number" then
            table.insert(result, k)
        end
    end
    return result
end

-- return index of element equal to val or nil if not found
function table:index(val)
    for i, v in ipairs(self) do
        if v == val then
            return i
        end
    end
end

-- directory name part of file path
function dirname(filename)
    return string.match(filename, ".*/") or "."
end

-- concatenate file path, first element must not be empty
function path_concat(result, ...)
    TRACE("PATH_CONCAT", result, ...)
    if result ~= "" then
        for _, v in ipairs({...}) do
            local sep = string.sub(result, -1) ~= "/" and string.sub(v, 1, 1) ~= "/" and "/" or ""
            result = result .. sep .. v
        end
        TRACE("PATH_CONCAT->", result)
        return result
    end
end

-- check whether path points to a directory
function is_dir(path)
    if path then
        local st, err = lstat(path)
        TRACE("IS_DIR?", st, err)
        if st and access(path, "x") then
            TRACE("IS_DIR", path, stat_isdir(st.st_mode))
            return stat_isdir(st.st_mode) ~= 0
        end
    end
end

--
function scan_files(dir)
    TRACE("SCANFILES", dir)
    local result = {}
    assert(dir, "empty directory argument")
    local files = glob(path_concat(dir, "*"))
    if files then
        for _, f in ipairs(files) do
            if is_dir(f) then
                for _, ff in ipairs(scan_files(f)) do
                    table.insert(result, ff)
                end
            else
                table.insert(result, f)
            end
        end
    end
    return result
end

--
function scan_dirs(dir)
    TRACE("SCANDIRS", dir)
    local result = {}
    assert(dir, "empty directory argument")
    local files = glob(path_concat(dir, "*"))
    if files then
        for _, f in ipairs(files) do
            if is_dir(f) then
                table.insert(result, f)
                for _, ff in ipairs(scan_dirs(f)) do
                    table.insert(result, ff)
                end
            end
        end
    end
    return result
end

-- set global variable to first parameter that is a directory
local function init_global_path(...)
    for _, dir in pairs({...}) do
        if is_dir(path_concat(dir, ".")) then
            if string.sub(dir, -1) ~= "/" then
                dir = dir .. "/"
            end
            return dir
        end
    end
    error("init_global_path")
end

-- return first parameter that is an existing executable
local function init_global_cmd(...)
    for _, n in ipairs({...}) do
        if access(n, "x") then
            return n
        end
    end
    error("init_global_cmd")
end

-- global tables for full paths of used Unix commands and relevant directories
CMD = {}
PATH = {}
PARAM = {}

-- initialize global variables after reading configuration files
-- return first existing directory with a trailing "/" appended
local function init_globals()
    chdir("/")

    -- important commands
    CMD.chroot = init_global_cmd("/usr/sbin/chroot")
    CMD.ldconfig = init_global_cmd("/sbin/ldconfig")
    CMD.make = init_global_cmd("/usr/bin/make")
    CMD.sysctl = "/sbin/sysctl"
    CMD.mv = "/bin/mv"
    CMD.unlink = "/bin/unlink"
    CMD.df = "/bin/df"
    CMD.umount = "/sbin/umount"
    CMD.mdconfig = "/sbin/mdconfig"
    CMD.realpath = "/bin/realpath"
    CMD.mkdir = "/bin/mkdir"
    CMD.rmdir = "/bin/rmdir"
    CMD.cp = "/bin/cp"
    CMD.pwd_mkdb = "/usr/sbin/pwd_mkdb"
    CMD.rm = "/bin/rm"
    CMD.ln = "/bin/ln"
    CMD.pkg_b = "/usr/sbin/pkg" -- pkg dummy in base system used for pkg bootstrap
    CMD.env = "/usr/bin/env"
    CMD.sh = "/bin/sh"
    CMD.ktrace = "/usr/bin/ktrace" -- testing only
    CMD.mktemp = "/usr/bin/mktemp"
    CMD.grep = "/usr/bin/grep"
    CMD.pkg_bootstrap = "/usr/sbin/pkg"

    local t = Origin.port_var(nil, {
        table = true,
        "LOCALBASE",
        "PORTSDIR",
        "DISTDIR",
        "PACKAGES",
        "PKG_DBDIR",
        "PORT_DBDIR",
        "WRKDIRPREFIX",
        "DISABLE_LICENSES",
    })

    PATH.localbase = init_global_path(t.LOCALBASE, "/usr/local")
    PATH.local_lib = init_global_path(path_concat(PATH.localbase, "lib"))
    PATH.local_lib_compat = init_global_path(path_concat(PATH.local_lib, "compat/pkg"))

    -- port infrastructure paths, may be modified by user
    PATH.portsdir = init_global_path(t.PORTSDIR, "/usr/ports")
    PATH.distdir = init_global_path(t.DISTDIR, path_concat(PATH.portsdir, "distfiles"))
    PARAM.distdir_ro = not access(PATH.distdir, "rw") -- need sudo to fetch or purge distfiles

    PATH.packages = init_global_path(Options.local_packagedir,
                                     t.PACKAGES,
                                     path_concat(PATH.portsdir, "packages"),
                                     "/usr/packages")
    PATH.packages_backup = init_global_path(PATH.packages .. "portmaster-backup")
    PARAM.packages_ro = not access(PATH.packages, "rw") -- need sudo to create or delete package files

    PATH.pkg_dbdir = init_global_path(t.PKG_DBDIR, "/var/db/pkg") -- no value returned for make -DBEFOREPORTMK
    PARAM.pkg_dbdir_ro = not access(PATH.pkg_dbdir, "rw") -- need sudo to update the package database

    PATH.port_dbdir = init_global_path(t.PORT_DBDIR, "/var/db/ports")
    PARAM.port_dbdir_ro = not access(PATH.port_dbdir, "rw") -- need sudo to record port options

    PATH.wrkdirprefix = init_global_path(t.WRKDIRPREFIX, "/")
    PARAM.wrkdir_ro = not access(path_concat(PATH.wrkdirprefix, PATH.portsdir), "rw") -- need sudo to build ports

    PATH.tmpdir = init_global_path(os.getenv("TMPDIR"), "/tmp")

    CMD.pkg = init_global_cmd(path_concat(PATH.localbase, "sbin/pkg-static"))
    CMD.sudo = init_global_cmd(path_concat(PATH.localbase, "sbin/pkg-static"))

    -- Bootstrap pkg if not yet installed
    if not access(CMD.pkg, "x") then
        Exec.run{as_root = true, CMD.pkg_bootstrap, "bootstrap"}
    end

    --
    PARAM.uid = geteuid() -- getuid() ???
    local pw_entry = getpwuid(PARAM.uid)
    PARAM.user = pw_entry.pw_name
    PARAM.home = pw_entry.pw_dir
    TRACE("PW_ENTRY", PARAM.uid, PARAM.user, PARAM.home)

    -- set package formats unless already specified by user
    PARAM.package_format = Options.package_format or "txz"
    PARAM.backup_format = Options.backup_format or "txz"

    -- some important global variables
    PARAM.abi = chomp(Exec.run {safe = true, CMD.pkg, "config", "abi"})
    PARAM.abi_noarch = string.match(PARAM.abi, "^[^:]+:[^:]+:") .. "*"

    -- determine number of CPUs (threads)
    PARAM.ncpu = tonumber (Exec.run {safe = true, CMD.sysctl, "-n", "hw.ncpu"})

    -- global variables for use by the distinfo cache and distfile names file (for ports to be built)
    -- PARAM.distfiles_perport = PATH.distdir .. "DISTFILES.perport" -- port names and names of distfiles required by the latest port version
    -- PARAM.distfiles_list = PATH.distdir .. "DISTFILES.list" -- current distfile names of all ports

    -- has license framework been disabled by the user
    PARAM.disable_licenses = t.DISABLE_LICENSES
end

-------------------------------------------------------------------------------------
-- set sane defaults and cache some buildvariables in the environment
-- <se> ToDo convert to sub-shell and "export -p | egrep '^(VAR1|VAR2)'" ???
local function init_environment()
    -- reset PATH to a sane default
    setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin:" .. PATH.localbase .. "bin:" .. PATH.localbase .. "sbin")
    local portsdir = PATH.portsdir
    local scriptsdir = path_concat(portsdir, "Mk/Scripts")
    local cmdenv = {SCRIPTSDIR = scriptsdir, PORTSDIR = portsdir, MAKE = "make"}
    local env_lines = Exec.run {table = true, safe = true, env = cmdenv, CMD.sh, path_concat(scriptsdir, "ports_env.sh")}
    for _, line in ipairs(env_lines) do
        local var, value = line:match("^export ([%w_]+)=(.+)")
        if string.sub(value, 1, 1) == '"' and string.sub(value, -1) == '"' then
            value = string.sub(value, 2, -2)
        end
        TRACE("SETENV", var, value)
        setenv(var, value)
    end
    -- prevent delays for messages that are not displayed, anyway
    setenv("DEV_WARNING_WAIT", "0")
end

--[[
-- replace passed package or port with one built from the new origin
local function ports_add_changed_origin(build_type, name, o_n) -- 3rd arg is NOT optional
    if Options.force then build_type = "force" end
    Msg.show {
        level = 1,
        start = true,
        "Checking upgrades for",
        name,
        "and ports it depends on ..."
    }
    local origins = PkgDb.origins_flavor_from_glob(
                  name or PkgDb.origins_flavor_from_glob(name .. "*") or
                      o_o_from_port(name))
    assert(origins, "Could not find package or port matching " .. name)
    for i, o_o in ipairs(origins) do
        choose_action(build_type, "run", o_o, o_n) -- && matched=1
    end
end
--]]

-- ---------------------------------------------------------------------------
-- ask whether some file should be deleted (except when -n or -y enforce a default answer)
-- move to Msg module
-- convert to return table of files to delete?
local function ask_and_delete(prompt, files)
    local msg_level = 1
    local answer
    if Options.default_no then
        answer = "q"
    end
    if Options.default_yes then
        answer = "a"
    end
    for _, file in ipairs(files) do
        if answer ~= "a" and answer ~= "q" then
            answer = Msg.read_answer("Delete " .. prompt .. " '" .. file .. "'", "y", {"y", "n", "a", "q"})
        end
        if answer == "a" then
            msg_level = 0
        end
        --
        if answer == "a" or answer == "y" then
            if Options.default_yes or answer == "a" then
                Msg.show {level = msg_level, "Deleting", prompt .. ":", file}
            end
            Exec.spawn(Exec.run, {as_root = PARAM.distdir_ro, log = true, CMD.unlink, file})
        elseif answer == "q" or answer == "n" then
            if Options.default_no or answer == "q" then
                Msg.show {level = 1, "Not deleting", prompt .. ":", file}
            end
        end
    end
    Exec.finish_spawned()
end

-- ask whether some directory and its contents  should be deleted (except when -n or -y enforce a default answer)
local function ask_and_delete_directory(prompt, dirs)
    -- move to Msg module -- convert to return table of directories to delete?
    local msg_level = 1
    local answer
    if Options.default_no then
        answer = "q"
    end
    if Options.default_yes then
        answer = "a"
    end
    for _, directory in ipairs(dirs) do
        if answer ~= "a" and answer ~= "q" then
            answer = Msg.read_answer("Delete " .. prompt .. " '" .. directory .. "'", "y", {"y", "n", "a", "q"})
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
                if is_dir(directory) then
                    for _, file in ipairs(glob(directory .. "/*")) do
                        Exec.run {as_root = true, log = true, CMD.unlink, file}
                    end
                    Exec.run {as_root = true, log = true, CMD.rmdir, directory}
                end
            end
        elseif answer == "q" or answer == "n" then
            if Options.default_no or answer == "q" then
                Msg.show {level = 1, "Not deleting", prompt .. ":", directory}
            end
        end
    end
end

-- # delete package files that do not belong to any currently installed port (except portmaster backup packages)
local function packagefiles_purge() -- move to new PackageFile module ???
    error("NYI")
end

-------------------------------------------------------------------------------------
--
local distinfo_cache = {}

local function fetch_distinfo(pkg)
   local o_o = pkg.origin
   if o_o then
      local f = o_o.distinfo_file
      if f then
         local t = Distfile.parse_distinfo(f)
         for k, v in pairs(t) do
            distinfo_cache[k] = v
         end
      end
   end
end

-- offer to delete old distfiles that are no longer required by any port
local function clean_stale_distfiles ()
    Msg.show {start = true, "Gathering list of distribution files of all installed ports ..."}
    local packages = Package.installed_pkgs()
    for _, pkg in ipairs(packages) do
        Exec.spawn (fetch_distinfo, pkg)
    end
    Exec.finish_spawned(fetch_distinfo)
    chdir(PATH.distdir)
    local distfiles = scan_files("")
    local unused = {}
    for _, f in ipairs(distfiles) do
        if not distinfo_cache[f] then
            unused[#unused + 1] = f
        end
    end
    if #unused == 0 then
        Msg.show {"No stale distfiles found"}
    else
        ask_and_delete ("stale file", unused)
        local distdirs = scan_dirs("")
        if #distdirs > 0 then
            table.sort(distdirs, function (a, b) return a > b end)
        end
        for _, v in ipairs(distdirs) do
            Exec.run{as_root = PARAM.distdir_ro, CMD.rmdir, v}
        end
    end
end

--
local function list_stale_libraries()
    -- create list of shared libraries used by packages and create list of compat libs that are not required (anymore)
    local activelibs = {}
    local lines = PkgDb.query {table = true, glob = true, "%B", "*"}
    for _, lib in ipairs(lines) do
        activelibs[lib] = true
    end
    -- list all active shared libraries in some compat directory
    local compatlibs = {}
    local ldconfig_lines = Exec.run {table = true, safe = true, CMD.ldconfig, "-r"} -- safe flag required ???
    for _, line in ipairs(ldconfig_lines) do
        local lib = line:match(" => " .. PATH.localbase .. "lib/compat/pkg/(.*)")
        if lib and not activelibs[lib] then
            compatlibs[lib] = true
        end
    end
    return table.keys(compatlibs)
end

-- delete stale compat libraries (i.e. those no longer required by any installed port)
local function shlibs_purge()
    Msg.show {start = true, "Scanning for stale shared library backups ..."}
    local stale_compat_libs = list_stale_libraries()
    if #stale_compat_libs then
        table.sort(stale_compat_libs)
        ask_and_delete("stale shared library backup", stale_compat_libs)
    else
        Msg.show {"No stale shared library backups found."}
    end
end

-------------------------------------------------------------------------------------
-- delete stale options files
local function portdb_purge()
    Msg.show {start = true, "Scanning", PATH.port_dbdir, "for stale cached options:"}
    local origins = {}
    local origin_list = PkgDb.query {table = true, "%o"}
    for _, origin in ipairs(origin_list) do
        local subdir = origin:gsub("/", "_")
        origins[subdir] = origin
    end
    assert(chdir(PATH.port_dbdir), "cannot access directory " .. PATH.port_dbdir)
    local stale_origins = {}
    for _, dir in ipairs(glob("*")) do
        if not origins[dir] then
            table.insert(stale_origins, dir)
        end
    end
    if #stale_origins then
        ask_and_delete_directory("stale port options file for", stale_origins)
    else
        Msg.show {"No stale entries found in", PATH.port_dbdir}
    end
    chdir("/")
end

-- list ports (optionally with information about updates / moves / deletions)
local function list_ports(mode)
    local filter = {
        {
            "root ports (no dependencies and not depended on)", function(pkg)
                return pkg.num_depending == 0 and pkg.num_dependencies == 0 and pkg.is_automatic == false
            end,
        }, {
            "trunk ports (no dependencies but depended on)", function(pkg)
                return pkg.num_depending ~= 0 and pkg.num_dependencies == 0
            end,
        }, {
            "branch ports (have dependencies and are depended on)", function(pkg)
                return pkg.num_depending ~= 0 and pkg.num_dependencies ~= 0
            end,
        }, {
            "leaf ports (have dependencies but are not depended on)", function(pkg)
                return pkg.num_depending == 0 and pkg.num_dependencies ~= 0 and pkg.is_automatic == false
            end,
        }, {
            "left over ports (e.g. build tools that are not required at run-time)", function(pkg)
                return pkg.num_depending == 0 and pkg.is_automatic == true
            end,
        },
    }
    local listdata = {}
    local function check_version(pkg_old)
        TRACE("CHECK_VERSION_SPAWNED", pkg_old.name)
        local o_o = pkg_old.origin
        assert(o_o, "no origin for package " .. pkg_old.name)
        local pkg_new = o_o.pkg_new
        local pkgname_new = pkg_new and pkg_new.name
        local reason
        if not pkgname_new then
            local o_n = o_o:lookup_moved_origin()
            reason = o_o.reason
            TRACE("MOVED??", reason)
            if o_n and o_n ~= o_o then
                pkg_new = o_n.pkg_new
                pkgname_new = pkg_new and pkg_new.name
            end
        end
        local result
        if not pkgname_new then
            if reason then
                result = "has been removed: " .. reason
            else
                result = "cannot be found in the ports system"
            end
        elseif pkgname_new ~= pkg_old.name then
            result = "needs update to " .. pkgname_new
        end
        listdata[pkg_old.name] = result or ""
    end
    local pkg_list = Package:installed_pkgs()
    Msg.show {start = true, "List of installed packages by category:"}
    for _, f in ipairs(filter) do
        local descr = f[1]
        local test = f[2]
        local rest = {}
        local count = 0
        for _, pkg_old in ipairs(pkg_list) do
            if test(pkg_old) then
                count = count + 1
            end
        end
        if count > 0 then
            Msg.show{start = true, count, descr}
            listdata = {}
            for _, pkg_old in ipairs(pkg_list) do
                if test(pkg_old) then
                    if mode == "verbose" then
                        Exec.spawn(check_version, pkg_old)
                    else
                        listdata[pkg_old.name] = ""
                    end
                else
                    table.insert(rest, pkg_old)
                end
            end
            Exec.finish_spawned()
            local pkgnames = table.keys(listdata)
            TRACE("PKGNAMES", #pkgnames)
            table.sort(pkgnames)
            for _, pkg_old in ipairs(pkgnames) do
                TRACE("LIST", pkg_old)
                Msg.show{pkg_old, listdata[pkg_old]}
            end
            pkg_list = rest
        end
    end
    assert(pkg_list[1] == nil, "not all packages covered in tests")
end

-------------------------------------------------------------------------------------
-- TRACEFILE = "/tmp/pm.cmd-log" -- DEBUGGING EARLY START-UP ONLY -- GLOBAL

-------------------------------------------------------------------------------------
local function main()
    -- print (umask ("755")) -- ERROR: results in 7755, check the details of this function
    -- shell ({to_tty = true}, "umask")

    -- load option definitions from table
    local args = Options.init()

    -- initialise global variables based on default values and rc file settings
    init_globals()

    -- do not ask for confirmation if not connected to a terminal
    if not ttyname(0) then
        stdin = io.open("/dev/tty", "r")
        if not stdin then
            Options.no_confirm = true
        end
    end

    -- disable setting the terminal title if output goes to a pipe or file (fd=3 is remapped from STDOUT)
    if not ttyname(2) then
        Options.no_term_title = true
    end
    -- initialize environment variables based on globals set in prior functions
    init_environment()

    --
    --Exec.spawn(Package.installed_pkgs, "")

    -------------------------------------------------------------------------------------
    -- plan tasks based on parameters passed on the command line
    PARAM.phase = "scan"

    if Options.replace_origin then
        if #args ~= 1 then
            error("exactly one port or packages required with -o")
        end
        ports_add_changed_origin("force", args, Options.replace_origin)
    elseif Options.all then
        Strategy.add_all_outdated()
    elseif Options.all_old_abi then
        ports_add_all_old_abi() -- create from ports_add_all_outdated() ???
    end

    --  allow the specification of -a and -r together with further individual ports to install or upgrade
    if #args > 0 then
        --dbg()
        args.force = Options.force
        Strategy.add_multiple(args)
    end

    --
    Strategy.execute()

    -------------------------------------------------------------------------------------
    -- non-upgrade operations supported by portmaster - executed after upgrades if requested
    if Options.check_depends then
        Exec.run {to_tty = true, CMD.pkg, "check", "-dn"}
    end
    if Options.list then
        list_ports(Options.list)
    end
    if Options.list_origins then
        PkgDb.list_origins()
    end
    -- if Options.delete_build_only then delete_build_only () end
    -- should have become obsolete due to build dependency tracking
    if Options.clean_stale_libraries then
        shlibs_purge()
    end
    -- if Options.clean_compat_libs then clean_stale_compat_libraries () end -- NYI
    if Options.clean_packages then
        packagefiles_purge()
    end
    if Options.deinstall_unused then
        packages_delete_stale()
    end
    if Options.check_port_dbdir then
        portdb_purge()
    end
    -- if Options.expunge then expunge (Options.expunge) end
    if Options.scrub_distfiles then
        clean_stale_distfiles()
    end

    -- display package messages for all updated ports
    exit_cleanup(0)
    -- not reached
end

tracefd = io.open("/tmp/pm.log", "w")

local success, errmsg = xpcall(main, debug.traceback)
if not success then
    fail(errmsg)
end
os.exit(0)

--[[
	ToDo
	adjust port origins in stored package manifests (but not in backup packages)
	???automatically rebuild ports after a required shared library changed (i.e. when an old library of a dependency was moved to the backup directory)
	     ---> pkg query "%B %n-%v" | grep $old_lib


	use "pkg query -g "%B" "*" | sort -u" to get a list of all shared libraries required by the installed packages and remove all files not in this list from lib/compat/pkg.
	Additionally consider all files that still require libs in /lib/compat/pkg as outdated, independently of any version changes.

	Check whether FLAVORS have been removed from a port before trying to build it with a flavor. E.g. the removal of "qt4" caused ports with FLAVORS qt4 and qt5 to become qt5 only and non-flavored

	In jailed or repo modes, a full recursion has to be performed on run dependencies (of dependencies ...) or some deep dependencies may be missed and run dependencies of build dependencies may be missing

	BUGS

	-x does not always work (e.g. when a port is to be installed as a new dependency)
	installing port@flavor does not always work, e.g. the installation of devel/py-six@py36 fails if devl/py-six@py27 is already installed
	conflicts detected only in make install (conflicting files) should not cause an abort, but be delayed until the conflicting package has been removed due to being upgraded
		in that case, the package of new new conflicting port has already been created and it can be installed from that (if the option to save the package had been given)

	-o <o_n> -r <name>: If $o_n is set, then the dependencies must be relative to the version built from that origin!!!

	--delayed-installation does not take the case of a run dependency of a build dependency into account!
	If a build dependency has run dependencies, then these must be installed as soon as available, as if they were build dependencies (since they need to exist to make the build dependency runnable)

	--force or --recursive should prevent use of already existing binaries to satisfy the request - the purpose is to re-compile those ports since some dependency might have incompatibly changed

	failure in the configuration phase (possibly other phases, too) lead to empty o_n and then to a de-installation of the existing package!!! (e.g. caused by update conflict in port's Makefile)

	restart file: in jailed/repo-mode count only finished "build-only" packages as DONE, but especially do not count "provided" packages, which might be required as build deps for a later port build
--]]

--[[
	General build policy rules (1st match decides!!!):

	Build_Dep_Flag := Build_Type = Provide
	UsePkgfile_Flag := Build_Type != Force && Pkgfile exists
	Late_Flag := Delayed/Jailed && Build_Dep=No
	Temp_Flag := Direct/Delayed && Run_Dep=No && Force=No && User=No

	ERROR:
		Run_Dep=No && Build_Dep=No
		Run_Dep=No && Build_Type=User

	Jail_Install:
		Mode=Jailed/Repo && Build_Dep=Yes

	Base_Install:
		Mode=Direct/Delayed/Jailed && Upgrade=Yes
		Mode=Direct/Delayed/Jailed && Build_Type=Force

		|B_Type	| B_Dep	| R_Dep	| Upgr	|   JailInst
	Mode	| A F U	|  Y N	|  Y N	|  Y N	|InJail	|cause
	------|-------|-------|-------|-------|-------|-------
	 *	| A F U	|    N	|    N	|   -	| ERROR	|-
	 *	|     U	|   -	|    N	|   -	| ERROR	|-
	 D/L	| A F U	|   -	|   -	|   -	|   -	|NoJail
	 J/R	| A F U	|    N	|  Y	|   -	|   -	|BuildNo
	 J/R	| A F U	|  Y	|   -	|   -	|  Yes	|Build

		|B_Type	| B_Dep	| R_Dep	| Upgr	|    BaseInst
	Mode	| A F U	|  Y N	|  Y N	|  Y N	|InBase	| P J B R F U
	------|-------|-------|-------|-------|-------|------------
	 D/L	| A	|  Y	|    N	|  Y	| Temp	| - - B - - U
	 L/J	|   F  	|    N	|  Y	|   -	| Late	| -   - R F
	 L/J	| A   U	|    N	|  Y	|  Y	| Late	| -   - R - U
	 D/L	|   F  	|   -	|   -	|   -	|  Yes	| - -     F
	 D/L	| A   U	|   -	|   -	|  Y	|  Yes	| - -     - U
	 L/J	|   F  	|  Y	|  Y	|   -	|  Yes	| -   B R F
	 L/J	| A   U	|  Y	|  Y	|  Y	|  Yes	| -   B R - U

	Usage_Mode:
	D = Direct installation
	L = deLayed installation
	J = Jailed build
	R = Repository mode

	Build_Type:
	A = Automatic
	F = Forced
	U = User request

	Installation_Mode (BaseInst):
	Temp = Temporary installation
	Late = Installation after completion of all port builds
	Yes  = Direct installation from a port or package

	----------------------------------------------------------------------------

	Build-Deps:

	For jailed builds and if delete-build-only is set:
	==> Register for each dependency (key) which port (value) relies on it
	==> The build dependency (key) can be deleted, if it is *not also a run dependency* and after the dependent port (value) registered last has been built

	Run-Deps:

	For jailed builds only (???):
	==> Register for each dependency (key) which port (value) relies on it
	==> The run dependency (key) can be deinstalled, if the registered port (value) registered last has been deinstalled


	b r C D J -----------------------------------------------------------------------------

	b r C     classic port build and installation:
	b r C      - recursively build/install build deps if new or version changed or forced
	b r C      - build port
	b r C      - create package
	b r C      - deinstall old package
	b r C      - install new version
	b r C      - recursively build/install run deps if new or version changed or forced

	b r C     classic package installation/upgrade:
	b r C      - recursively provide run deps (from port or package)
	b r C      - deinstall old package
	b r C      - install new package

	b r   D   delay-installation port build (of build dependency):
	b r   D    - recursively build/install build deps if new or version changed or forced
	b r   D    - build port
	b r   D    - create package
	b r   D    - deinstall old package
	b r   D    - install new version
	b r   D    - recursively build/install run deps if new or version changed or forced

	  r   D   delay-installation port build (not a build dependency):
	  r   D    - recursively build/install build deps if new or version changed or forced
	  r   D    - build port
	  r   D    - create package
	  r   D    - register package for delayed installation / upgrade


	b     D    - recursively build/install build deps if new or version changed or forced
	b     D    - build port
	b     D    - create package
	b     D    - deinstall old package
	b     D    - install new version
	b     D    - recursively build/install run deps if new or version changed or forced



	b     D   delay-installation package installation (of build dependency):
	b     D    - recursively build/install run deps
	b     D    - deinstall old package
	b     D    - install new version
	      D
	  r   D   delay-installation package installation (not a build dependency):
	  r   D    - register package for delayed installation / upgrade

	b       J jailed port build (of build dependency):
	b       J  - recursively build/install build deps in jail
	b       J  - build port
	b       J  - create package
	b       J  - install new version in jail
	b       J  - recursively build/install run deps in jail
	b       J  - register package for delayed installation / upgrade

	  r     J jailed port build (not a build dependency):
	  r     J  - recursively build/install build deps in jail
	  r     J  - build port
	  r     J  - create package
	  r     J  - register package for delayed installation / upgrade


	b       J jailed package installation (of build dependency):
	b       J  - recursively build/install run deps in jail
	b       J  - install package in jail
	b       J  - register package for delayed installation / upgrade depending on user options

	  r     J jailed package installation (not a build dependency):
	  r     J  - register package for delayed installation / upgrade

	          repo-mode is identical to jailed builds but without installation in base
--]]

--[[
	-----------------------
	Invocation of "make -V $VAR" - possible speed optimization: query multiple variables and cache result

	# --> register_depends
	origin_var "$dep_origin" FLAVOR

	# --> origin_from_dir
	origin_var "$dir" PKGORIGIN

	# --> dist_fetch_overlap
	origin_var "$origin" ALLFILES
	origin_var "$origin" DIST_SUBDIR

	# --> distinfo_update_cache
	origin_var "$origin" DISTINFO_FILE

	# --> port_flavors_get
	origin_var "$origin" FLAVORS

	# --> port_is_interactive
	origin_var "$o_n" IS_INTERACTIVE

	# --> check_license
	origin_var "$o_n" LICENSE

	# --> *
	origin_var "$o_n" PKGNAME

	# --> package_check_build_conflicts
	origin_var "$o_n" BUILD_CONFLICTS

	# --> choose_action, (list_ports)
	origin_var "$o_o" PKGNAME

	# --> origin_from_dir_and_pkg
	origin_var "$o_o" PKGORIGIN

	# --> choose_action
	origin_var_jailed "$o_o" PKGNAME

	# --> choose_action, origin_from_dir_and_pkg
	origin_var_jailed "$o_n" PKGNAME
--]]

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
--]]
