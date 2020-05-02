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

-- ----------------------------------------------------------------------------------
--
-- list dependencies for given origin and phase (build, run, test, all)
local DEPEND_ARGS = {
   build = "-V PKG_DEPENDS -V EXTRACT_DEPENDS -V PATCH_DEPENDS -V FETCH_DEPENDS -V BUILD_DEPENDS -V LIB_DEPENDS",
   run = "-V RUN_DEPENDS -V LIB_DEPENDS",
   test = "-V TEST_DEPENDS",
   -- package = "",
}
DEPEND_ARGS.all = DEPEND_ARGS.build .. " -V RUN_DEPENDS"

local function list (origin, dep_type)
   TRACE (origin.name, dep_type)
   local args = DEPEND_ARGS[dep_type]
   assert (args, "No dependency check defined for phase '" .. dep_type .. "'")
   local lines = origin:port_make {table = true, safe = true, dep_type .. "-depends-list"}
   local result = {}
   for i, line in ipairs (lines) do
      table.insert (result, Origin:new (line:match (".*/([^/]+/[^/]+)$")))
   end
   return result
end

-- module interface
return {
   list = list,
}
