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
local Exec = require("portmaster.exec")
local Lock = require("portmaster.lock")
local Param = require("portmaster.param")
local Trace = require("portmaster.trace")
local Util = require("portmaster.util")
local Msg = require("portmaster.msg")
local CMD = require("portmaster.cmd")
local Filepath = require("portmaster.filepath")

-------------------------------------------------------------------------------------
local TRACE = Trace.trace

-------------------------------------------------------------------------------------
--[[
TIMESTAMP = 1587747990
SHA256 (bash/bash-5.0.tar.gz) = b4a80f2ac66170b2913efbfb9f2594f1f76c7b1afd11f799e22035d63077fb4d
SIZE (bash/bash-5.0.tar.gz) = 10135110
--]]

-- return table indexed by filename
local function parse_distinfo(origin)
    --TRACE("PARSE_DISTINFO", origin)
    local di_filename = origin.distinfo_file
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
               --TRACE("DISTINFO", key, file, value)
               result[file] = t
            end
        end
        io.close(di_file)
    end
    return result
end

--
local DISTINFO_CACHE = {}
local Fetching = {}

-- perform "make checksum", analyse status message and write success status to file (meant to be executed in a background task)
local FetchLock = Lock:new("FetchLock")

local function dist_fetch(origin)
   local function generate_distinfo()
      local result = {}
      TRACE("GENERATE_DISTINFO:", origin.name, origin.distfiles or {})
      for _, v in ipairs(origin.distfiles or {}) do
         v = string.match(v, "^(.*):") or v
         result[v] = rawget(DISTINFO_CACHE, v) or {}
      end
      TRACE("GENERATE_DISTINFO->", origin.name, result)
      return result
   end
   local function update_distinfo_cache(distinfo)
      local port = origin.port
      for file, di in pairs(distinfo) do
         --TRACE("UPDATE_DISTINFO_CACHE", file, DISTINFO_CACHE[file], di)
         local di_c = DISTINFO_CACHE[file]
         if di_c and next(di) then
            --TRACE("DI", di, di_c)
            assert(di.SIZE == di_c.SIZE and di.SHA256 == di_c.SHA256 and di.TIMESTAMP == di_c.TIMESTAMP,
                  "Distinfo mismatch for " .. file .. " between " .. port .. " and " .. di.ports[1])
            table.insert(di_c.ports, port)
         else
            di_c = {SIZE = di.SIZE, SHA256 = di.SHA256, TIMESTAMP = di.TIMESTAMP, ports = {port}}
            DISTINFO_CACHE[file] = di_c
         end
         --TRACE("UPDATE_DISTINFO_CACHE->", file, DISTINFO_CACHE[file])
      end
   end
   local function fetch_required(filenames)
      local unchecked = {}
      table.sort(filenames)
      for _, file in ipairs(filenames) do
         --TRACE("FETCH_REQUIRED?", file, DISTINFO_CACHE[file])
         if DISTINFO_CACHE[file].checked == nil then
            --TRACE("FETCH_REQUIRED!", file)
            table.insert(unchecked, file)
         end
      end
      return unchecked
   end
   local function setall(di, field, value)
      for file, _ in pairs(di) do
         --TRACE("DISTINFO_CACHE", field, value, file)
         rawset (DISTINFO_CACHE[file], field, value)
      end
   end
   --TRACE("DIST_FETCH", origin and origin.name or "<nil>", origin and origin.distinfo_file or "<nil>")
   local port = origin.port
   local success = true
   local distinfo = generate_distinfo()
   update_distinfo_cache(distinfo)
   local distfiles = Util.table_keys(distinfo) -- or {} ???
   origin.distfiles = distfiles -- XXX why this assignment, distfiles had been set on entry into this function ???
   local unchecked = fetch_required(distfiles)
   origin.fetched = #unchecked == 0
   if not origin.fetched then
      -- >>>> FetchLock(unchecked)
      FetchLock:acquire(unchecked)
      local really_unchecked = fetch_required(unchecked) -- fetch again since we may have been blocked and sleeping
      if #really_unchecked > 0 then
         really_unchecked.tag = port.name
         Fetching[port] = true
         TRACE("FETCH_MISSING", really_unchecked)
         local lines, err, exitcode = origin:port_make{ -- XXX this requires to have all FETCH_DEPENDS installed! (but currently none exist in the ports tree)
            as_root = Param.distdir_ro,
            table = true,
            "FETCH_BEFORE_ARGS=-v",
            "NO_DEPENDS=1",
            "DISABLE_CONFLICTS=1",
            "DISABLE_LICENSES=1",
            "DEV_WARNING_WAIT=0",
            "checksum"
         }
         Fetching[port] = nil
         setall(distinfo, "checked", true)
         for _, l in ipairs(lines) do
            --TRACE("FETCH:", l)
            local files = string.match(l, "Giving up on fetching files: (.*)")
            if files then
               success = false
               origin.fetch_fail_msg = "Distfiles could not be fetched: " .. files
               for _, file in ipairs(Util.split_words(files)) do
                  --TRACE("DISTINFO_CACHE", "checked", false, file)
                  DISTINFO_CACHE[file].checked = false
               end
            end
         end
      end
      origin.fetched = success -- must be set before releasing FetchLock
      FetchLock:release(unchecked)
      -- <<<< FetchLock(unchecked)
   end
   --TRACE("FETCH->", port, success)
end

--
local function fetch(origin)
   if origin.distfiles then
      Exec.spawn(dist_fetch, origin)
   else
      origin.fetched = true
   end
end

--
local function fetch_wait(origin)
   local distfiles = origin.distfiles
   if distfiles then
      --TRACE("FETCH_WAIT", distfiles)
      distfiles.shared = true
      distfiles.tag = origin.name
      -- >>>> FetchLock(distfiles, SHARED)
      FetchLock:acquire(distfiles)
      FetchLock:release(distfiles) -- release immediately
      -- <<<< FetchLock(distfiles, SHARED)
   end
end

--
local function fetch_finish()
   --TRACE("FETCH_FINISH")
   if FetchLock and next(Fetching) then
      local ports = Util.table_keys(Fetching)
      table.sort(ports)
      Exec.finish_spawned(dist_fetch, "Finish background fetching and checking of " .. #ports .. " distribution files:\n\t" .. table.concat(ports, "\n\t"))
      FetchLock:destroy()
      FetchLock = false -- prevent further use as a table
   end
end

-------------------------------------------------------------------------------------
-- XXX move this functionality into the Distfiles module !!!
-- deletes files within a prefix path
local function batch_delete(filepath, files, as_root)
    for _, file in ipairs(files) do
      local fullpath = filepath + file
      TRACE("BATCH_DELETE", fullpath.name, as_root)
      if not Filepath.delete(fullpath) then
         Exec.run{
               as_root = true,
               log = true,
               CMD.unlink, fullpath.name
         }
        end
    end
end

--
local function delete_empty_directories(path, as_root)
    local dirs = path.find_dirs
    TRACE("DELETE_EMPTY_DIRS", path, dirs)
    if #dirs > 0 then
        table.sort(dirs, function (a, b) return a.name > b.name end)
    end
    for _, v in ipairs(dirs) do
        Exec.run{
            as_root = as_root,
            CMD.rmdir,
            (path + v.name).name
        }
    end
end

--
local distinfo_cache = {}

-- offer to delete old distfiles that are no longer required by any port
local function clean_stale(Origin, all_pkgs)
    local function fetch_distinfo(pkg) -- move to Cache module
        local o_o = Origin:new(pkg.origin_name)
        TRACE("FETCH_DISTINFO", pkg.name, pkg.origin_name, o_o)
        if o_o then
            local f = o_o.distinfo_file
            if f then
                local t = parse_distinfo(o_o)
                for k, v in pairs(t) do
                    TRACE("DISTINFO_ADD", k, v)
                    distinfo_cache[k] = v
                end
            end
        end
    end
    Msg.show {start = true, "Gathering list of distribution files of all installed ports ..."}
    for _, pkg in ipairs(all_pkgs) do -- move to Cache module
        Exec.spawn (fetch_distinfo, pkg)
    end
    Exec.finish_spawned(fetch_distinfo)
    local distfiles = Param.distdir.find_files
    local unused = {}
    for _, f in ipairs(distfiles) do
        local filename = f.name
        if not distinfo_cache[filename] then
            unused[#unused + 1] = filename
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

return {
    fetch = fetch,
    fetch_finish = fetch_finish,
    fetch_wait = fetch_wait,
    parse_distinfo = parse_distinfo,
    clean_stale = clean_stale,
}
