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

local Action = require("Action")
local Msg = require("Msg")

--
local function add_missing_deps()
     for i, a in ipairs(Action.list()) do
        if a.pkg_new and rawget(a.pkg_new, "is_installed") then
            -- print (a, "is already installed")
        else
            local add_dep_hdr = "Add build dependencies of " .. a.short_name
            local deps = a.build_depends or {}
            for _, dep in ipairs(deps) do
                local o = Origin:new(dep)
                local p = o.pkg_new
                if not ACTION_CACHE[p.name] then
                    if add_dep_hdr then
                        Msg.show {level = 2, start = true, add_dep_hdr}
                        add_dep_hdr = nil
                    end
                    -- local action = Action:new {build_type = "auto", dep_type = "build", o_n = o}
                    local action = Action:new{
                        build_type = "auto",
                        dep_type = "build",
                        pkg_new = p,
                        o_n = o
                    }
                    p.is_build_dep = true
                    -- assert (not o.action)
                    -- o.action = action -- NOT UNIQUE!!!
                end
            end
            add_dep_hdr = "Add run dependencies of " .. a.short_name
            deps = a.run_depends or {}
            for _, dep in ipairs(deps) do
                local o = Origin:new(dep)
                local p = o.pkg_new
                if not ACTION_CACHE[p.name] then
                    if add_dep_hdr then
                        Msg.show {level = 2, start = true, add_dep_hdr}
                        add_dep_hdr = nil
                    end
                    -- local action = Action:new {build_type = "auto", dep_type = "run", o_n = o}
                    local action = Action:new{
                        build_type = "auto",
                        dep_type = "run",
                        pkg_new = p,
                        o_n = o
                    }
                    p.is_run_dep = true
                    -- assert (not o.action)
                    -- o.action = action -- NOT UNIQUE!!!
                end
            end
        end
    end
end

return {
    add_missing_deps = add_missing_deps,
}
