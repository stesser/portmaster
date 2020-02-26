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

-- perform "make checksum", analyse status message and write success status to file (meant to be executed in a background task)
local function dist_fetch (origin)
--   Msg.cont (3, "Fetch distfiles for '" .. port .. "'")
   local port = origin:port ()
   local result = ""
   local lines = origin:port_make {table = true, safe = true, "-D", "NO_DEPENDS", "-D", "DISABLE_CONFLICTS", "-D", "DISABLE_LICENSES", "DEV_WARNING_WAIT=0", "checksum"}
   for i, l in ipairs (lines) do
      local files = string.match (l, "Giving up on fetching files: (.*)")
      if files then
	 for i, file in ipairs (split_words (files)) do
	    result = result .. " " ..  file
	 end
      end
   end
   if result ~= "" then
      Msg.cont (3, "Fetching distfiles for '" .. port .. "' failed:" .. result)
      return "NOTOK " .. port .. " missing/wrong checksum:" .. result
   end
   return "OK " .. port .. " "
end

TMPFILE_FETCH_ACK = nil -- GLOABL
fetchq = nil -- pipe used as fetch request queue -- GLOBAL

-- fetch and check distfiles (in background?)
local function fetch (origin)
   local name = tostring (origin) -- convert to origin string ???
   -- global variables
   if not TMPFILE_FETCH_ACK then
      TMPFILE_FETCH_ACK = tempfile_create ("ACK")
      local fetchqr, fetchqw = pipe ()
      local pid, errmsg	= fork ()
      assert (pid, errmsg)
      if pid == 0 then
	 -- child process
	 close(fetchqw)
	 local inpfile = io.stdin
	 dup2 (fetchqr, fileno (io.stdin)) -- stdin
	 local fetch_ack = io.open (TMPFILE_FETCH_ACK, "a+")
	 fetch_ack:setvbuf ("line")
	 --print ("WRITE FETCH_ACK to", TMPFILE_FETCH_ACK)
	 --
	 local fds = {[fetchqr] = {events = {IN = true}}}
	 local done
	 local buffer = ""
	 while not done do
	    poll (fds, -1)
	    for fd in pairs (fds) do
	       if fds[fd].revents.IN then
		  buffer = buffer .. read (fd, 1024)
	       end
	       if fds[fd].revents.HUP then
		  fds[fd] = nil
		  close (fd)
		  if not next (fds) then
		     done = true
		  end
	       end
	    end
	    local pos
	    repeat
	       pos = string.find (buffer, "\n", 1, true)
	       if pos then
		  local port = string.sub (buffer, 1, pos - 1)
		  buffer = string.sub (buffer, pos + 1, -1)
		  if port ~= "" then
		     origin = Origin:new (port)
		     local status = dist_fetch (origin)
		     fetch_ack:write (status .. "\n")
		     TRACE ("-->", status)
		  end
	       end
	    until not pos
	 end
	 fetch_ack:close ()
	 _exit (0)
      else
	 close (fetchqr)
	 fetchq = fdopen (fetchqw, "w")
      end
   end
   fetchq:write (name .. "\n")
end

--
local function fetch_finish ()
   if fetchq then
      fetchq:write ("\n\n")
      fetchq:close ()
      fetchq = nil
   end
end

-- delete old distfiles
local function delete_old (origin_new, pkgname_old)
   --error ("NYI")
   return true
end

-- create file with port origins and distfiles required by each port
function update_list ()
   chdir (PORTSDIR)
   local result = {}
   local origins = {}
   local origin_list = PkgDb.query {"%o"}
   for i, origin in ipairs (origin_list) do
      if not origins[origin] then
	 origins[origin] = true
	 local file = origin .. "/distinfo"
	 if not access (file, "r") then
	    file = origin.distinfo_file
	    if not file or not access (file, "r") then
	       local origin_new = origin_find_moved (origin)
	       if origin_new and origin ~= origin_new then
		  file = origin_new.distinfo_file
		  origin = origin_new
	       end
	    end
	 end
	 if file then
	    file = file:gsub(".*/([^/]+/[^/]+/[^/]+)$", "%1")
	    local difile = io.open (file, "r")
	    if difile then
	       for line in difile:lines ("*L") do
		  local file, size = line:match ("SIZE [(](%S+)[)] = (%d+)")
		  if size then
		     if not result[file] then
			result[file] = {}
		     end
		     table.insert (result[file], origin)
		  end
	       end
	       difile:close ()
	    end
	 end
      end
   end
   local outfile = io.open (DISTFILES_LIST .. "~", "w")
   local distfiles = table.keys (result)
   table.sort (distfiles)
   for i, file in ipairs (distfiles) do
      outfile:write (file .. " " .. table.concat (result[file], " ") .. "\n")
   end
   outfile:close ()
   os.rename (DISTFILES_LIST .. "~", DISTFILES_LIST)
   return result
end

-- preserve file names and hashes of distfiles from new port
function distinfo_cache_update (origin_new, pkgname_new)
   Msg.cont (2, "NYI: distinfo_cache_update", origin_new, pkgname_new)
--   error("NYI")
end

--# ---------------------------------------------------------------------------
--# return list of stale distfiles that previously have been used to build some specific package
--# function #list_stale_distfiles_pkg ()
--#	local pkgname="$1"
--#	local distfiles_file
--#
--#	local distfiles_file="$PKG_DBDIR/$pkgname/distfiles"
--#
--#	[ -s "$distfiles_file" ] || return 1
--#	update_distfiles_list
--#	grep ^DISTFILE: "$distfiles_file" | cut -d":" -f2 | sort | ${GREP_CMD} -v -f "$distfiles_list"
--#}

-- offer to delete old distfiles that are no longer required by any port
local function clean_stale ()
   if chdir (DISTDIR) then
      Msg.start (0, "Gathering list of distribution files for installed ports ...")
      -- create list of current distfiles for installed ports
      local act_distfiles = Distfile.update_list ()
      -- query user whether distfiles are to be deleted
      -- local stale_distfiles = shell ("find", {"-x", ".", "-type", "f", "|", "sed", "-e", "s![.]/!!", "|", "sort", "|", GREP_CMD, "-vF", "-f", DISTFILES_LIST})
      local distfiles = scan_dir (DISTDIR)
      if distfiles then
	 local stale_distfiles = {}
	 for i, f in ipairs (distfiles) do
	    if not act_distfiles[f] then
	       table.insert (stale_distfiles, f)
	    end
	 end
	 if #stale_distfiles then
	    -- table.sort (stale_distfiles) -- already in ascending order ...
	    ask_and_delete ("stale file", stale_distfiles)
	 else
	    Msg.cont (0, "No stale distfiles found")
	 end
      end
      shell ("find", {"-x", DISTDIR, "-type", "d", "-empty", "-delete"})
   end
end

return {
   fetch = fetch,
   fetch_finish = fetch_finish,
   update_list = update_list,
   clean_stale = clean_stale,
}
