#!/usr/local/bin/lua53

--[[
SPDX-License-Identifier: BSD-2-Clause-FreeBSD

Copyright (c) 2019-2021 Stefan Eßer <se@freebsd.org>

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

local P_US = require("posix.unistd")
local chdir = P_US.chdir

--[[
function trace (event, line)
   local s = debug.getinfo (2).short_src
   print (s .. ":" .. line)
end
debug.sethook (trace, "l")
--]]

local R = require("std.strict")

-- local _debug = require 'std._debug'(true)

-------------------------------------------------------------------------------------
local Package = require("portmaster.package")
local Options = require("portmaster.options")
local Msg = require("portmaster.msg")
local Progress = require("portmaster.progress")
local Distfile = require("portmaster.distfiles")
local Exec = require("portmaster.exec")
local PkgDb = require("portmaster.pkgdb")
local Strategy = require("portmaster.strategy")
local CMD = require("portmaster.cmd")
local Param = require("portmaster.param")
local Moved = require("portmaster.moved")
local Environment = require("portmaster.environment")
local Trace = require("portmaster.trace")
local Origin = require("portmaster.origin")
local Filepath = require("portmaster.filepath")
local Util = require("portmaster.util")

-------------------------------------------------------------------------------------
local TRACE = Trace.trace

-------------------------------------------------------------------------------------
-- clean up when script execution ends
local function exit_cleanup(exitcode)
    if CMD.stty then
        Exec.run{CMD.stty, "sane"}
    end
    exitcode = exitcode or 0
    Progress.clear()
    Distfile.fetch_finish()
    --Options.save()
    Msg.success_show()
    Trace.init() -- implies close of trace file
    os.exit(exitcode)
    -- not reached
end

-- abort script execution with an error message
local function fail(...)
    Msg.show {start = true, "ERROR:", ...}
    -- Msg.show {"Fix the issue and use '" .. PROGRAM, "-R' to restart"}
    Msg.show {"Aborting update"}
    exit_cleanup(1)
    -- not reached
end

-- abort script execution with an internal error message on unexpected error
local function fail_bug(...)
    Msg.show {"INTERNAL ERROR:", ...}
    Msg.show {"Aborting update"}
    exit_cleanup(10)
    -- not reached
end

-------------------------------------------------------------------------------------
--[[
--
local function scan_files(dir)
    TRACE("SCANFILES", dir)
    local result = {}
    assert(dir, "empty directory argument")
    local files = (Filepath:new(dir) + "*").files
    if files then
        for _, f in ipairs(files) do
            if Filepath.is_dir(f) then
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
local function scan_dirs(dir)
    --TRACE("SCANDIRS", dir)
    local result = {}
    assert(dir, "empty directory argument")
    local files = (Filepath:new(dir) + "*").files
    if files then
        for _, f in ipairs(files) do
            if Filepath.is_dir(f) then
                table.insert(result, f)
                for _, ff in ipairs(scan_dirs(f)) do
                    table.insert(result, ff)
                end
            end
        end
    end
    return result
end
--]]

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
-- deletes files within a prefix path
local function batch_delete(filepath, files, as_root)
    local function do_unlink(file, as_root)
        Exec.run{
            as_root = as_root,
            log = true,
            CMD.unlink, file
        }
    end
    for _, file in ipairs(files) do
        local fullpath = filepath + file
        Exec.spawn(do_unlink, fullpath.name, as_root)
    end
    Exec.finish_spawned(do_unlink)
end

--
local function delete_empty_directories(path, as_root)
    TRACE("DELETE_EMPTY_DIRS", path)
    --local dirs = scan_dirs(path.name)
    local dirs = path.find_dirs()
    if #dirs > 0 then
        table.sort(dirs, function (a, b) return a > b end)
    end
    for _, v in ipairs(dirs) do
        Exec.run{
            as_root = as_root,
            CMD.rmdir, (path + v).name
        }
    end
end

-------------------------------------------------------------------------------------
--
local distinfo_cache = {}

-- offer to delete old distfiles that are no longer required by any port
local function clean_stale_distfiles ()
    local function fetch_distinfo(pkg) -- move to Cache module
        local o_o = Origin:new(pkg.origin_name)
        TRACE("FETCH_DISTINFO", pkg.name, pkg.origin_name, o_o)
        if o_o then
            local f = o_o.distinfo_file
            if f then
                local t = Distfile.parse_distinfo(o_o)
                for k, v in pairs(t) do
                    TRACE("DISTINFO_ADD", k, v)
                    distinfo_cache[k] = v
                end
            end
        end
    end
    Msg.show {start = true, "Gathering list of distribution files of all installed ports ..."}
    for _, pkg in ipairs(Strategy.all_pkgs()) do -- move to Cache module
        Exec.spawn (fetch_distinfo, pkg)
    end
    Exec.finish_spawned(fetch_distinfo)
    local distfiles = Param.distdir.find_files
    local unused = {}
    for _, f in ipairs(distfiles) do
        if not distinfo_cache[f] then
            unused[#unused + 1] = f
        end
    end
    if #unused == 0 then
        Msg.show {"No stale distfiles found"}
    else
        local selected = Msg.ask_to_delete ("stale file", unused)
        batch_delete(Param.distdir, selected, Param.distdir_ro)
        delete_empty_directories(Param.distdir, Param.distdir_ro)
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
    local ldconfig_lines = Exec.run{
        table = true,
        safe = true, -- safe flag required ???
        CMD.ldconfig, "-r"
    }
    for _, line in ipairs(ldconfig_lines) do
        local lib = line:match(" => " .. (Param.local_lib_compat + "(.*)").name)
        if lib and not activelibs[lib] then
            compatlibs[lib] = true
        end
    end
    return Util.table_keys(compatlibs)
end

-- delete stale compat libraries (i.e. those no longer required by any installed port)
local function clean_stale_libraries()
    Msg.show {start = true, "Scanning for stale shared library backups ..."}
    local stale_compat_libs = list_stale_libraries()
    if #stale_compat_libs > 0 then
        table.sort(stale_compat_libs)
        local selected = Msg.ask_to_delete("stale shared library backup", stale_compat_libs, false, true)
        batch_delete(Param.local_lib_compat, selected, true)
    else
        Msg.show {"No stale shared library backups found."}
    end
end

-------------------------------------------------------------------------------------
-- delete stale options files
local function portdb_purge()
    Msg.show {start = true, "Scanning", Param.port_dbdir, "for stale cached options:"}
    local origins = {}
    local origin_list = PkgDb.query {table = true, "%o"}
    for _, origin in ipairs(origin_list) do
        local subdir = origin:gsub("/", "_")
        origins[subdir] = origin
    end
    assert(chdir(Param.port_dbdir.name), "cannot access directory " .. Param.port_dbdir)
    local stale_origins = {}
    for _, dir in ipairs(glob("*")) do
        if not origins[dir] then
            table.insert(stale_origins, dir)
        end
    end
    if #stale_origins then
        local selected = Msg.ask_to_delete("stale port options file for", stale_origins)
        batch_delete(Param.port_dbdir, selected, Param.port_dbdir_ro)
    else
        Msg.show {"No stale entries found in", Param.port_dbdir}
    end
    chdir("/")
end

--
local function list_origins()
    local origins = {}
    for _, pkg in ipairs(Strategy.all_pkgs()) do
        if pkg.num_depending == 0 and not pkg.is_automtic then
            local o = pkg.origin
            if o then
                local n = o.name
                if n then
                    n = string.match (n, "^[^%%]*")
                    origins[n] = true
                end
            end
        end
    end
    local list = Util.table_keys(origins)
    table.sort(list)
    Msg.show{verbatim = true, table.concat(list, "\n"), "\n"}
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
    local listdata
    local function check_version(pkg_old)
        --TRACE("CHECK_VERSION_SPAWNED", pkg_old.name)
        local o_o = Origin:new(pkg_old.origin_name)
        assert(o_o, "no origin for package " .. pkg_old.name)
        local pkg_new = Package:new(o_o.pkgname)
        local pkgname_new = pkg_new and pkg_new.name
        local reason
        if not pkgname_new then
            local o_n = Moved.new_origin(o_o)
            TRACE("MOVED??", o_o.name, o_n and o_n.name or "<nil>")
            if o_n ~= o_o then
                reason = rawget(o_o, "reason")
                if o_n then
                    pkg_new = Package:new(o_n.pkgname)
                    pkgname_new = pkg_new and pkg_new.name
                end
            end
        end
        local result = ""
        if not pkgname_new then
            if reason then
                result = "has been removed: " .. reason
            else
                result = "cannot be found in the ports system"
            end
        elseif pkgname_new ~= pkg_old.name then
            result = "needs update to " .. pkgname_new
        end
        if o_o and rawget(o_o, "expiration_date") then
            if result and result ~= "" then
                result = result .. " and "
            end
            result = result .. "will be removed: " .. o_o.expiration_date .. ": " .. o_o.deprecated
        end
        listdata[pkg_old.name] = result
    end
    local pkg_list = Strategy.all_pkgs()
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
                    rest[#rest+1] = pkg_old
                end
            end
            Exec.finish_spawned()
            local pkgnames = Util.table_keys(listdata)
            --TRACE("PKGNAMES", #pkgnames)
            table.sort(pkgnames)
            for _, pkg_old in ipairs(pkgnames) do
                --TRACE("LIST", pkg_old)
                Msg.show{pkg_old, listdata[pkg_old]}
            end
            pkg_list = rest
        end
    end
    assert(next(pkg_list) == nil, "not all packages covered in tests")
end

-------------------------------------------------------------------------------------
local function main()
    -- print (umask ("755")) -- ERROR: results in 7755, check the details of this function
    -- shell ({to_tty = true}, "umask")

    -- load option definitions from table
    local args = Options.init()
    if Options.developer_mode then
        Trace.init("/tmp/pm.log")
    end

     -- initialize environment variables based on globals set in prior functions
    Environment.init()

    -------------------------------------------------------------------------------------
    -- plan tasks based on parameters passed on the command line
    Param.phase = "scan"

    Strategy.init()

    if Options.replace_origin then
        if #args ~= 1 then
            error("exactly one port or packages required with -o")
        end
        ports_add_changed_origin("force", args, Options.replace_origin) -- XXX NYI
    elseif Options.all then
        Strategy.add_all_installed()
    elseif Options.all_old_abi then
        ports_add_all_old_abi() -- XXX create from ports_add_all_outdated() ??? NYI
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
        PkgDb.check_depends()
    end
    if Options.list then
        list_ports(Options.list)
    end
    if Options.list_origins then
        list_origins()
    end
    -- if Options.delete_build_only then delete_build_only () end
    -- should have become obsolete due to build dependency tracking
    if Options.clean_stale_libraries then
        clean_stale_libraries()
    end
    -- if Options.clean_compat_libs then clean_stale_compat_libraries () end -- NYI
    if Options.clean_packages then
        Packages.clean_stale_files()
    end
    if Options.deinstall_unused then
        packages_delete_stale() -- XXX NYI
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
