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
local Options = require("portmaster.options")
local Exec = require("portmaster.exec")
local CMD = require("portmaster.cmd")
local Param = require("portmaster.param")
local Trace = require("portmaster.trace")
local Util = require("portmaster.util")
local Filepath = require("portmaster.filepath")

-------------------------------------------------------------------------------------
local P_US = require("posix.unistd")
local rmdir = P_US.rmdir
local TRACE = Trace.trace

-- ---------------------------------------------------------------------------
-- fstype, mount point, option (size, ro/rw for fstype="null", or linrdlink for Linux "fdesc")
local JAIL_FS = {
    ["/"] = {fs_type = "tmp", fs_opt = "size=1m"},
    ["/bin"] = {fs_type = "null"},
    ["/compat/linux"] = {fs_type = "tmp", fs_opt = "size=4g"},
    ["/compat/linux/proc"] = {fs_type = "linproc"},
    ["/compat/linux/sys"] = {fs_type = "linsys"},
    ["/compat/linux/dev/fd"] = {fs_type = "fdesc", fs_opt = "linrdlnk"},
    ["/dev"] = {fs_type = "dev"},
    ["/dev/fd"] = {fs_type = "fdesc"},
    ["/etc"] = {fs_type = "tmp", fs_opt = "size=64m"},
    ["/lib"] = {fs_type = "null"},
    ["/libexec"] = {fs_type = "null"},
    ["/proc"] = {fs_type = "proc"},
    ["/sbin"] = {fs_type = "null"},
    ["/tmp"] = {fs_type = "tmp", fs_opt = "size=1g"},
    --   ["/usr"]				= { fs_type = "null",	 			},
    ["/usr/bin"] = {fs_type = "null"},
    ["/usr/include"] = {fs_type = "null"},
    ["/usr/lib"] = {fs_type = "null"},
    ["/usr/lib32"] = {fs_type = "null"},
    ["/usr/libdata"] = {fs_type = "null"},
    ["/usr/libexec"] = {fs_type = "null"},
    ["/usr/local"] = {fs_type = "tmp", fs_opt = "size=12g"},
    ["/usr/local/bin"] = {fs_type = "dir"},
    ["/usr/local/etc"] = {fs_type = "dir"},
    ["/usr/local/lib32"] = {fs_type = "dir"},
    ["/usr/local/lib/compat/pkg"] = {fs_type = "dir"},
    ["/usr/local/libexec"] = {fs_type = "dir"},
    ["/usr/local/sbin"] = {fs_type = "dir"},
    ["/usr/local/share"] = {fs_type = "dir"},
    ["/usr/local/var"] = {fs_type = "dir"},
    ["/usr/packages"] = {fs_type = "null", fs_opt = "ro"},
    ["/usr/ports"] = {fs_type = "null"},
    ["/usr/ports/distfiles"] = {fs_type = "null"},
    ["/usr/sbin"] = {fs_type = "null"},
    ["/usr/share"] = {fs_type = "null"},
    ["/usr/src"] = {fs_type = "null"},
    ["/usr/tests"] = {fs_type = "null"},
    ["/usr/work"] = {fs_type = "tmp", fs_opt = "size=12g"},
    ["/var"] = {fs_type = "tmp", fs_opt = "size=1g"},
    ["/var/db"] = {fs_type = "tmp", fs_opt = "size=4g"},
    ["/var/db/fontconfig"] = {fs_type = "dir"},
    ["/var/db/pkg"] = {fs_type = "dir"},
    ["/var/db/ports"] = {fs_type = "null"},
    ["/var/run"] = {fs_type = "dir"},
    ["/var/tmp"] = {fs_type = "dir"},
}

-- ---------------------------------------------------------------------------
local function unmount_all(jaildir)
    --TRACE("UNMOUNT_ALL", jaildir)
    local dir = jaildir and jaildir.name
    assert(dir == Param.jailbase.name, "invalid jail directory " .. jaildir.name .. " passed")
    local mnt_dev, mnt_point, md_unit
    local df_lines = Exec.run{
        table = true,
        safe = true,
        CMD.df
    }
    for i = #df_lines, 2, -1 do
        mnt_dev, mnt_point = string.match(df_lines[i], "^(%S*)%s.*%s(/%S*)$")
        if string.match(mnt_point, "^" .. dir) then
            md_unit = string.match(mnt_dev, "^/dev/md(.+)")
            --TRACE("UNMOUNT", mnt_point, md_unit)
            Exec.run{
                as_root = true,
                log = true,
                CMD.umount, mnt_point
            }
            if md_unit then
                Exec.run{
                    as_root = true,log = true,
                    CMD.mdconfig, "-d", "-u", md_unit
                }
            end
            rmdir(mnt_point)
        end
    end
end

-- (UTIL)
local function do_mount(fs_type, from, onto, param)
    local args = {
        as_root = true,
        log = true,
        CMD.mount
    }
    if fs_type then
        table.insert(args, "-t")
        table.insert(args, fs_type .. "fs")
    end
    if param then
        table.insert(args, "-o")
        table.insert(args, param)
    end
    table.insert(args, from)
    table.insert(args, onto)
    local _, _, exitcode = Exec.run(args)
    return exitcode == 0
end

local function mount_dir(fs_type, what, where, param)
    -- nothing to be done, the directory has already been created ...
    return true
end

local function mount_null(fs_type, what, where, param)
    --TRACE("MOUNT_NULL", fs_type, what, where, param)
    param = param or "ro"
    assert(param == "rw" or param == "ro", "Invalid parameter '" .. param .. "' passed to jail mount of " .. where)
    --   local real_fs = Exec.run {safe = true, CMD.realpath, what}
    --   if dir_is_fsroot (real_fs) then
    return do_mount("null", what, where, param)
    --   end
    --   return true
end

local function mount_special(fs_type, what, where, param)
    assert(not param or param == "linrdlnk",
           "Invalid parameter '" .. (param or "<nil>") .. "' passed to jail mount of " .. where)
    return do_mount(fs_type, what, where, param)
end

local function mount_tmp(fs_type, what, where, param)
    param = param or "size=4g" -- make tunable ...
    return do_mount("tmp", what, where, param .. ",mode=1777")
end

-- ---------------------------------------------------------------------------
-- mount one filesystem of given fs_type
local MOUNT_PROCS = {
    dev = mount_special,
    dir = mount_dir,
    fdesc = mount_special,
    linproc = mount_special,
    linsys = mount_special,
    null = mount_null,
    proc = mount_special,
    tmp = mount_tmp,
    -- union =	mount_union,
}

--
local function mount_all(jaildir)
    local dirs = Util.table_keys(JAIL_FS)
    table.sort(dirs) -- make sure parent dirs come before sub dirs
    local df_lines = Exec.run{
        table = true,
        safe = true,
        CMD.df, table.unpack(dirs)
    }
    for i, dir in ipairs(dirs) do
        local mnt_point = string.match(df_lines[i + 1], ".*%s(/%S*)$")
        local spec = JAIL_FS[dir]
        local fs_type = spec.fs_type
        local mount_opt = spec.fs_opt
        local real_fs = Exec.run{
            safe = true,
            CMD.realpath, dir
        }
        local where = jaildir + real_fs
        --TRACE("MOUNT", fs_type, jaildir, dir, mnt_point, real_fs, where, mount_opt or "<nil>")
        if not where.is_dir then
            Exec.run{
                as_root = true,
                CMD.mkdir, "-p", where.name
            }
            assert(where.is_dir) -- assert that mount point directory has been created
        end
        local mount_proc = MOUNT_PROCS[fs_type]
        assert(mount_proc, "unknown file system type " .. fs_type .. " for " .. dir)
        mount_proc(fs_type, real_fs, where.name, mount_opt)
    end
end

-- ---------------------------------------------------------------------------
-- user and group id ranges to be excluded from copying to the jail (GLOBAL)
local JAIL_UID_EXCL_LOW = 1000
local JAIL_UID_EXCL_HIGH = 65530
local JAIL_GID_EXCL_LOW = 1000
local JAIL_GID_EXCL_HIGH = 65530

-- ---------------------------------------------------------------------------
local function provide_file(jaildir, ...)
    local dir
    local files = {...}
    for _, file in ipairs(files) do
        dir = (jaildir + file).parent
        Exec.run{
            CMD.mkdir, "-p", dir.name
        } -- use direct LUA function
        Exec.run{
            CMD.cp, "-pR", file, dir.name
        } -- copy with LUA
    end
end

-- create (partially filtered) copies of most relevant files from /etc in the jail (must be run under root account, currently)
local function setup_etc(jaildir)
    assert(jaildir.name and #jaildir.name > 0, "Empty jaildir in jail_create_etc")
    assert((jaildir + "/etc").is_dir, "Destination directory " .. jaildir.name .. "/etc does not exist")
    -- create /etc/passwd and /etc/master.passwd
    local inpf = io.open("/etc/passwd", "r")
    assert(inpf)
    local outf1 = io.open((jaildir + "/etc/passwd").name, "w+")
    local outf2 = io.open((jaildir + "/etc/master.passwd").name, "w+")
    assert(outf1 and outf2)
    local gids = {}
    for line in inpf:lines() do
        local user, pwd, uid, gid, geos, home, shell =
            line:match("^([^#][^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")
        if user then
            uid = tonumber(uid)
            if uid < JAIL_UID_EXCL_LOW or JAIL_UID_EXCL_HIGH < uid then
                outf1:write(line .. "\n")
                outf2:write(user .. ":" .. pwd .. ":" .. uid .. ":" .. gid .. "::0:0:" .. geos .. ":" .. home .. ":" .. shell ..
                                "\n")
            end
            gids[gid] = true
        end
    end
    inpf:close()
    outf1:close()
    outf2:close()
    Exec.run{
        CMD.pwd_mkdb, "-d", (jaildir + "/etc").name, (jaildir + "/etc/master.passwd").name
    }

    -- create /etc/group
    local inpf = io.open("/etc/group", "r")
    assert(inpf)
    local outf1 = io.open((jaildir + "/etc/group").name, "w+")
    assert(outf1)
    for line in inpf:lines() do
        local group, pwd, gid, groups = line:match("^([^#][^:]*):([^:]*):([^:]*):([^:]*)")
        if group then
            gid = tonumber(gid)
            if gids[gid] or gid < JAIL_GID_EXCL_LOW or JAIL_GID_EXCL_HIGH < gid then
                outf1:write(line .. "\n")
            end
        end
    end
    inpf:close()
    outf1:close()
    -- further required files are copied unmodified
    provide_file(jaildir, "/etc/shells", "/etc/rc.subr", "/etc/make.conf", "/etc/src.conf", "/etc/rc.d", "/etc/defaults")
    provide_file(jaildir, (Param.localbase + "/etc/pkg.conf").name, (Param.localbase + "/etc/pkg").name, "/var/log/utx.log")
end

local function setup_var_run(jaildir)
    Exec.run{
        as_root = true,
        jailed = true,
        log = true,
        CMD.ldconfig, "/lib", "/usr/lib", (Param.localbase + "lib").name
    }
    Exec.run{
        as_root = true,
        jailed = true,
        log = true,
        CMD.ldconfig, "-32", "/usr/lib32", (Param.localbase + "lib32").name
    }
end

local function setup_usr_local(jaildir)
    provide_file(jaildir, (Param.localbase + "/etc/portmaster.rc").name)
end

-- ---------------------------------------------------------------------------
local JAILROOT = "/tmp"

local function create()
    if not Options.dry_run then
        Param.jailbase = Filepath:new(JAILROOT) + "TEST" -- NYI use individual jail names

        unmount_all(Param.jailbase)
        mount_all(Param.jailbase)
        setup_etc(Param.jailbase)
        setup_var_run(Param.jailbase)
        setup_usr_local(Param.jailbase)
    end
end

local function destroy()
    if not Options.dry_run and not Options.developer_mode then
        unmount_all(Param.jailbase)
    end
    Param.jailbase = nil
end

return {create = create, destroy = destroy}
