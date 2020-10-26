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

local CMD = {}

CMD.chown = "/usr/sbin/chown"
CMD.chroot = "/usr/sbin/chroot"
CMD.cp = "/bin/cp"
CMD.df = "/bin/df"
CMD.env = "/usr/bin/env"
CMD.grep = "/usr/bin/grep"
CMD.ktrace = "/usr/bin/ktrace" -- testing only
CMD.ldconfig = "/sbin/ldconfig"
CMD.ln = "/bin/ln"
CMD.make = "/usr/bin/make"
CMD.mdconfig = "/sbin/mdconfig"
CMD.mkdir = "/bin/mkdir"
CMD.mktemp = "/usr/bin/mktemp"
CMD.mount = "/sbin/mount"
CMD.mv = "/bin/mv"
CMD.pkg = "/usr/local/sbin/pkg-static"
CMD.pkg_bootstrap = "/usr/sbin/pkg" -- pkg dummy in base system used for pkg bootstrap
CMD.pwd_mkdb = "/usr/sbin/pwd_mkdb"
CMD.realpath = "/bin/realpath"
CMD.rm = "/bin/rm"
CMD.rmdir = "/bin/rmdir"
CMD.sh = "/bin/sh"
CMD.stty = "/bin/stty"
CMD.sudo = "/usr/local/bin/sudo"
CMD.sysctl = "/sbin/sysctl"
CMD.umount = "/sbin/umount"
CMD.unlink = "/bin/unlink"

return CMD
