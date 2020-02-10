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

-- ---------------------------------------------------------------------------
-- fstype, mount point, option (size, ro/rw for fstype="null", or linrdlink for Linux "fdesc")
local JAIL_FS = {
   { "tmp",	"/",			"1m"		},
   { "null",	"/bin"					},
   { "tmp",	"/compat/linux",	"4g"		},
   { "linproc",	"/compat/linux/proc"			},
   { "linsys",	"/compat/linux/sys"			},
   { "fdesc",	"/compat/linux/dev/fd",	"linrdlnk"	},
   { "dev",	"/dev"					},
   { "fdesc",	"/dev/fd"				},
   { "tmp",	"/etc",			"64m"		},
   { "null",	"/lib"					},
   { "null",	"/libexec"				},
   { "proc",	"/proc"					},
   { "null",	"/sbin"					},
   { "tmp",	"/tmp",			"1g"		},
   { "null",	"/usr"					},
   { "null",	"/usr/bin"				},
   { "null",	"/usr/include"				},
   { "null",	"/usr/lib"				},
   { "null",	"/usr/lib32"				},
   { "null",	"/usr/libdata"				},
   { "null",	"/usr/libexec"				},
   { "tmp",	"/usr/local",		"12g"		},
   { "dir",	"/usr/local/bin"			},
   { "dir",	"/usr/local/etc"			},
   { "dir",	"/usr/local/lib32"			},
   { "dir",	"/usr/local/lib/compat/pkg"		},
   { "dir",	"/usr/local/libexec"			},
   { "dir",	"/usr/local/sbin"			},
   { "dir",	"/usr/local/share"			},
   { "dir",	"/usr/local/var"			},
   { "null",	"/usr/packages",	"ro"		},
   { "null",	"/usr/ports"				},
   { "null",	"/usr/ports/distfiles"			},
   { "null",	"/usr/sbin"				},
   { "null",	"/usr/share"				},
   { "null",	"/usr/src"				},
   { "null",	"/usr/tests"				},
   { "tmp",	"/usr/work",		"12g"		},
   { "tmp",	"/var",			"1g"		},
   { "tmp",	"/var/db",		"4g"		},
   { "dir",	"/var/db/fontconfig"			},
   { "dir",	"/var/db/pkg"				},
   { "null",	"/var/db/ports"				},
   { "dir",	"/var/run"				},
   { "dir",	"/var/tmp"				},
}

-- ---------------------------------------------------------------------------
local function umount_all (jaildir)
   assert (jaildir and jaildir == JAILROOT, "invalid jail directory " .. jaildir .. " passed")
   local r = io.popen("mount -p", "r")
   local md_units = {}
   local dirs = {}
   for line in r:lines() do
      local mnt_dev, mnt_point = line:match ("(%S+)%s+(%S+)")
      if mnt_point == jaildir or strpfx (mnt_point, jaildir .. "/") then
	 if strpfx (mnt_dev, "/dev/md") then
	    md_units:insert (mnt_dev:sub(6))
	 end
	 dirs:insert (mnt_point)
      end
   end
   for i, mnt_point in ipairs (dirs) do
      shell ("umount", {as_root = true, mnt_point})
      assert (rmdir (mnt_point), "cannot delete mount point")
   end
   for i, md_dev in ipairs (md_units) do
      shell ("mdconfig", {as_root = true, "-d", "-u", md_dev})
   end
end

-- ---------------------------------------------------------------------------
local function dir_is_fsroot (dir)
   if not is_dir (dir) then
      return nil
   end
   local first = true
   for line in shell_pipe ("df", dir) do
      if first then
	 first = false
      else
	 line = line:match(".*%s(/%S*)$")
	 return line == dir
      end
   end
end

-- ---------------------------------------------------------------------------
local function mkdir_jailed (jaildir, path)
   local jail_path = jaildir .. "/" .. path
   if not is_dir (jail_path) then
      shell ("mkdir", {"-p", jail_path})
      if not is_dir (jail_path) then
	 mount (jaildir, "tmp", dirname (path), "1m")
	 shell ("mkdir", {"-p", jail_path})
      end
   end
   return jail_path
end

-- (UTIL)
local function do_mount (fs_type, from, onto, param)
   assert (fs_type)
   local args = {as_root = true, to_tty = true, "-t", fs_type .. "fs", from, onto}
   if param then
      table.insert (args, 1, "-o")
      table.insert (args, 2, param)
   end
   return shell ("mount", args)
end

local function mount_special (jaildir, fs_type, mnt_point, param)
   assert (not param or param == "linrdlnk",
	   "Invalid parameter '" .. param .. "' passed to jail mount of " .. mnt_point)
   return do_mount (fs_type, "-", mnt_point, param)
end

local function mount_dir (jaildir, fs_type, mnt_point, param)
   -- nothing to be done, the directory has already been created ...
   return true
end

local function mount_null (jaildir, fs_type, mnt_point, param)
   param = param or "ro"
   assert (param == "rw" or param == "ro",
	   "Invalid parameter '" .. param .. "' passed to jail mount of " .. mnt_point)
   local real_fs = shell ("realpath", {safe = true, mnt_point})
   if dir_is_fsroot (real_fs) then
      return do_mount (fs_type, real_fs, mnt_point, param)
   end
   return false -- or true ???
end

local function mount_tmp (jaildir, fs_type, mnt_point, param)
   param = param or "4G" -- make tunable ...
   return do_mount (fs_type, "-", mnt_point, param)
end

local function mount_union (jaildir, fs_type, mnt_point, param)
   param = param or "4G" -- make tunable ...
   local real_fs = real_path (mnt_point)
   if dir_is_fsroot (real_fs) then
      if not do_mount (fs_type, real_fs, mnt_point, param) then
	 return false
      end
      local md_dev = shell ("mdconfig", {as_root = true, "-a", "-s", param})
      if md_dev == "" then
	 shell ("umount", {as_root = true, mnt_point})
	 return nil -- error exit
      end
      shell ("newfs", {as_root = true, "-i", "10000", "-b", "4096", "-f", "4096", "/dev/" .. md_dev}) -- make tunable ...
      if not do_mount ("", "union", "/dev/" .. md_dev .. " " .. mnt_point) then
	 return false
      end
      for line in shell_pipe ("find", "-x", mnt_point, "-type", "d", "-print0 | xargs -0 -n1 -I% mkdir -p", jaildir .. "%") do
	 -- do nothing
      end
   end
   return true
end

-- mount one filesystem of given fs_type
local MOUNT_PROCS = {
   dev =	jail_mount_special,
   dir =	jail_mount_dir,
   fdesc =	jail_mount_special,
   linproc =	jail_mount_special,
   linsys =	jail_mount_special,
   null =	jail_mount_null,
   proc =	jail_mount_special,
   tmp = 	jail_mount_tmp,
   union =	jail_mount_union,
}

local function mount (jaildir, fs_type, mnt_point, param)
   local mnt_point = mkdir_jailed (jaildir, mnt_point)

   local mount_proc = MOUNT_PROCS[fs_type]
   assert (mount_proc, "unknown fs_type " .. fs_type)
   return mount_proc (jaildir, fs_type, mnt_point, param)
end
   
-- ---------------------------------------------------------------------------
-- return mountpoint of the file system the directory resides in on the host (outside jail)
local function mountpoint (dir)
   if dir then
      local first = true
      for line in shell_pipe ("df", dir) do
	 if first then
	    first = false
	 else
	    local mnt_pnt = line:match ("(%S+)$")
	    if #mnt_pnt > 0 then
	       if mnt_pnt == "/" then
		  mnt_pnt = dir
	       end
	       return mnt_pnt
	    end
	 end
      end
   end
end

-- ---------------------------------------------------------------------------
local function mount_all (jaildir)
   for i, mount_desc in ipairs (JAIL_FS) do
      mount_desc[4] = mountpoint (mount_desc[2])
   end
   for i, mount_desc in ipairs (JAIL_FS) do
      local fs_type, dir, mount_opt, mnt_pnt = table.unpack (mount_desc)
      print ("JAIL_MOUNT", fs_type, dir, mount_opt, mnt_pnt) -- ???
      if dir ~= mnt_pnt then
	 if mnt_pnt == "/" then
	    mount (jaildir, "tmp",  mnt_pnt)
	 else
	    if not dir_is_fsroot (jaildir .. "/" .. mnt_pnt) then
	       mount (jaildir, "null", mnt_pnt)
	    end
	 end
      end
      mount (jaildir, fs_type, dir, mount_opt)
   end
end

-- ---------------------------------------------------------------------------
-- user and group id ranges to be excluded from copying to the jail (GLOBAL)
local JAIL_UID_EXCL_LOW  = 1000
local JAIL_UID_EXCL_HIGH = 65530
local JAIL_GID_EXCL_LOW  = 1000
local JAIL_GID_EXCL_HIGH = 65530

-- ---------------------------------------------------------------------------
local function provide_file (jaildir, ...)
   local file, dir
   local files = {...}
   for i, file in ipairs (files) do
      dir = jaildir .. "/" .. dirname (file)
      shell ("mkdir", {"-p", dir}) -- use direct LUA function
      shell ("cp", {"-pR", file, dir}) -- copy with LUA
   end
end

-- create (partially filtered)  copies of most relevant files from /etc in the jail
local function setup_etc (jaildir)
   assert (jaildir and #jaildir > 0, "Empty jaildir in jail_create_etc")
   assert (is_dir (jaildir .. "/etc"), "Destination directory " .. jaildir .. "/etc does not exist")
   -- create /etc/passwd and /etc/master.passwd
   local inpf = io.open ("/etc/passwd", "r")
   assert (inpf)
   local outf1 = io.open (jaildir .. "/etc/passwd", "w+")
   local outf2 = io.open (jaildir .. "/etc/master.passwd", "w+")
   assert (outf1 and outf2)
   local gids = {}
   for line in inpf:lines() do
      if not strpfx (line, "#") then
	 local user, pwd, uid, gid, geos, home, shell = line:match ("([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")
	 if uid < JAIL_UID_EXCL_LOW or JAIL_UID_EXCL_HIGH < uid then
	    outf1:write (line .. "\n")
	    outf2:write (user .. ":" .. pwd .. ":" .. uid .. ":" .. gid .. "::0:0:" .. geos .. ":" .. home .. ":" .. shell)
	 end
	 gids[gid] = true
      end
   end
   inpf:close()
   outf1:close()
   outf2:close()
   shell ("pwd_mkdb", {"-d", jaildir .. "/etc", jaildir .. "/etc/master.passwd"})
   
   -- create /etc/group
   local inpf = io.open ("/etc/group", "r")
   assert (inpf)
   local outf1 = io.open (jaildir .. "/etc/group", "w+")
   assert (outf1)
   for line in inpf:lines() do
      if not strpfx (line, "#") then
	 local group, pwd, gid, groups = line:match ("([^:]*):([^:]*):([^:]*):([^:]*)")
	 if gids[gid] or gid < JAIL_GID_EXCL_LOW or JAIL_GID_EXCL_HIGH < gid then
	    outf1:write (line .. "\n")
	 end
      end
   end
   inpf:close()
   outf1:close()
   -- further required files are copied unmodified
   provide_file (jaildir, "/etc/shells", "/etc/rc.subr", "/etc/make.conf", "/etc/src.conf", "/etc/rc.d", "/etc/defaults")
   provide_file (jaildir, LOCALBASE .. "/etc/pkg.conf", LOCALBASE .. "/etc/pkg", "/var/log/utx.log")
end

local function setup_var_run (jaildir)
   run ("ldconfig", {jailed = true, "/lib", "/usr/lib", LOCALBASE .. "/lib"})
   run ("ldconfig", {jailed = true, "-32", "/usr/lib32", LOCALBASE .. "/lib32"})
end

local function setup_usr_local (jaildir)
   provide_file (jaildir, LOCALBASE .. "/etc/portmaster.rc")
end

-- ---------------------------------------------------------------------------
local JAILROOT = "/tmp"

local function create ()
   JAILBASE = JAILROOT .. "/TEST/" -- NYI use autoamtic jail names

   unmount_all (JAILBASE)

   mount_all (JAILBASE)
   setup_etc (JAILBASE)
   setup_var_run (JAILBASE)
   setup_usr_local (JAILBASE)
end

local function destroy ()
   unmount_all (JAILBASE)
   JAILBASE = nil
end

return {
   create = create,
   destroy = destroy,
}
