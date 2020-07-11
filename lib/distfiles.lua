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
local Exec = require("portmaster.exec")
local Lock = require("portmaster.locks")

-------------------------------------------------------------------------------------
local DISTINFO_CACHE = {}

--[[
TIMESTAMP = 1587747990
SHA256 (bash/bash-5.0.tar.gz) = b4a80f2ac66170b2913efbfb9f2594f1f76c7b1afd11f799e22035d63077fb4d
SIZE (bash/bash-5.0.tar.gz) = 10135110
--]]

-- return table indexed by filename
local function parse_distinfo(origin)
    local di_filename = origin.distinfo_file
    TRACE("PARSE_DISTINFO", di_filename)
    local result = {}
    local di_file = io.open(di_filename, "r")
    if di_file then --  meta-ports do not have a distinfo file
        local timestamp
        for line in di_file:lines() do
            timestamp = timestamp or string.match(line, "^TIMESTAMP = (%d+)")
            local key, file, value = string.match(line, "(%S+) %((%S+)%) = (%S+)")
            if key then
               local t = result[file] or {TIMESTAMP = timestamp}
               t[key] = value
               TRACE("DISTINFO", key, file, value)
               result[file] = t
            end
        end
        io.close(di_file)
    end
    return result
end

--
local function generate_distinfo(origin)
   local result = {}
   for _, v in ipairs(origin.distfiles or {}) do
      v = string.match(v, "^(.*):") or v
      result[v] = {}
   end
   TRACE("GENERATE_DISTINFO", origin.name, result)
   return result
end

-- perform "make checksum", analyse status message and write success status to file (meant to be executed in a background task)
local fetch_lock

local function dist_fetch(origin)
   local function update_distinfo_cache(distinfo)
      local port = origin.port
      for file, di in pairs(distinfo) do
         TRACE("UPDATE_DISTINFO_CACHE", file)
         local di_c = DISTINFO_CACHE[file]
         if di_c and next(di) then
            TRACE("DI", di, di_c)
            assert(di.SIZE == di_c.SIZE and di.SHA256 == di_c.SHA256 and di.TIMESTAMP == di_c.TIMESTAMP,
                  "Distinfo mismatch for " .. file .. " between " .. port .. " and " .. di.port[1])
            table.insert(di_c.port, port)
         else
            di_c = {SIZE = di.SIZE, SHA256 = di.SHA256, TIMESTAMP = di.TIMESTAMP, port = {port}}
            DISTINFO_CACHE[file] = di_c
         end
      end
   end
   local function fetch_required(filenames)
      local unchecked = {}
      table.sort(filenames)
      for _, file in ipairs(filenames) do
         TRACE("FETCH_REQUIRED?", file)
         if DISTINFO_CACHE[file].checked == nil then
            TRACE("FETCH_REQUIRED!", file)
            table.insert(unchecked, file)
         end
      end
      return unchecked
   end
   local function setall(di, field, value)
      for file, _ in pairs(di) do
         rawset (DISTINFO_CACHE[file], field, value)
      end
   end
   TRACE("DIST_FETCH", origin and origin.name or "<nil>", origin and origin.distinfo_file or "<nil>")
   local port = origin.port
   local success = false
   --local distinfo = parse_distinfo(origin)
   local distinfo = generate_distinfo(origin)
   update_distinfo_cache(distinfo)
   local distfiles = table.keys(distinfo) -- or {} ???
   origin.distfiles = distfiles
   local unchecked = fetch_required(distfiles)
   if #unchecked > 0 then
      fetch_lock = fetch_lock or Lock.new("FetchLock")
      Lock.acquire(fetch_lock, unchecked)
      unchecked = fetch_required(unchecked) -- fetch again since we may have been blocked and sleeping
      setall(distinfo, "fetching", true)
      TRACE("FETCH_MISSING", unchecked)
      local lines = origin:port_make{
         as_root = PARAM.distdir_ro,
         table = true,
         "FETCH_BEFORE_ARGS=-v",
         "NO_DEPENDS=1",
         "DISABLE_CONFLICTS=1",
         "DISABLE_LICENSES=1",
         "DEV_WARNING_WAIT=0",
         "checksum"
      }
      setall(distinfo, "fetching", false)
      success = true -- assume OK
      setall(distinfo, "checked", true)
      for _, l in ipairs(lines) do
         TRACE("FETCH:", l)
         local files = string.match(l, "Giving up on fetching files: (.*)")
         if files then
            success = false
            for _, file in ipairs(split_words(files)) do
               DISTINFO_CACHE[file].checked = false
            end
         end
      end
      Lock.release(fetch_lock, unchecked)
   end
   TRACE("FETCH->", port, success)
   return success
end

--
local function fetch(origin)
   Exec.spawn(dist_fetch, origin)
end

--
local function fetch_wait(origin)
   if fetch_lock then
      local distfiles = origin.distfiles
      TRACE("FETCH_WAIT", distfiles)
      distfiles.shared = true
      Lock.acquire(fetch_lock, distfiles)
      Lock.release(fetch_lock, distfiles) -- release immediately
   end
end

--
local function fetch_finish()
   TRACE("FETCH_FINISH")
   Exec.finish_spawned(fetch, "Finish background fetching and checking of distribution files")
   if fetch_lock then
      Lock.destroy(fetch_lock)
      fetch_lock = false -- prevent further use as a table
   end
end

return {
    fetch = fetch,
    fetch_finish = fetch_finish,
    fetch_wait = fetch_wait,
}
