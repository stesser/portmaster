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
local Action = require("Action")
local Msg = require("Msg")
local Options = require("Options")
local Jail = require("Jail")
local Progress = require("Progress")
local Distfile = require("Distfile")

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
                    local action = Action:new{build_type = "auto", dep_type = "build", pkg_new = p, o_n = o}
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
                    local action = Action:new{build_type = "auto", dep_type = "run", pkg_new = p, o_n = o}
                    p.is_run_dep = true
                    -- assert (not o.action)
                    -- o.action = action -- NOT UNIQUE!!!
                end
            end
        end
    end
end

--
local function sort_list(ACTION_LIST, ACTION_CACHE) -- remove ACTION_CACHE from function arguments !!!
    local max_str = tostring(#ACTION_LIST)
    local sorted_list = {}
    local function add_action(action)
        if not rawget(action, "planned") then
            local deps = rawget(action, "build_depends")
            if deps then
                for _, o in ipairs(deps) do
                    local origin = Origin.get(o)
                    local pkg_new = origin.pkg_new
                    local a = rawget(ACTION_CACHE, pkg_new.name)
                    TRACE("BUILD_DEP", a and rawget(a, "action"), origin.name, origin.pkg_new,
                          origin.pkg_new and rawget(origin.pkg_new, "is_installed"))
                    -- if a and not rawget (a, "planned") then
                    if a and not rawget(a, "planned") and not rawget(origin.pkg_new, "is_installed") then
                        add_action(a)
                    end
                end
            end
            assert(not rawget(action, "planned"), "Dependency loop for: " .. action:describe())
            table.insert(sorted_list, action)
            action.listpos = #sorted_list
            action.planned = true
            Msg.show {"[" .. tostring(#sorted_list) .. "/" .. max_str .. "]", tostring(action)}
            --
            deps = rawget(action, "run_depends")
            if deps then
                for _, o in ipairs(deps) do
                    local origin = Origin.get(o)
                    local pkg_new = origin.pkg_new
                    local a = rawget(ACTION_CACHE, pkg_new.name)
                    TRACE("RUN_DEP", a and rawget(a, "action"), origin.name, origin.pkg_new,
                          origin.pkg_new and rawget(origin.pkg_new, "is_installed"))
                    -- if a and not rawget (a, "planned") then
                    if a and not rawget(a, "planned") and not rawget(origin.pkg_new, "is_installed") then
                        add_action(a)
                    end
                end
            end
        end
    end

    Msg.show {start = true, "Sort", #ACTION_LIST, "actions"}
    for _, a in ipairs(ACTION_LIST) do
        Msg.show {start = true}
        add_action(a)
    end
    -- assert (#ACTION_LIST == #sorted_list, "ACTION_LIST items have been lost: " .. #ACTION_LIST .. " vs. " .. #sorted_list)
    return sorted_list
end

--
local function execute()
    if tasks_count() == 0 then
        -- ToDo: suppress if updates had been requested on the command line
        Msg.show {start = true, "No installations or upgrades required"}
    else
        -- all fetch distfiles tasks should have been requested by now
        Distfile.fetch_finish()
        -- display list of actions planned
        -- NYI register_delete_build_only ()

        Action.show_statistics()
        if Options.fetch_only then
            if Msg.read_yn("Fetch and check distfiles required for these upgrades now?", "y") then
                -- wait for completion of fetch operations
                -- perform_fetch_only () -- NYI wait for completion of fetch operations
            end
        else
            Progress.clear()
            if Msg.read_yn("Perform these upgrades now?", "y") then
                -- perform the planned tasks in the order recorded in ACTION_LIST
                Msg.show {start = true}
                Progress.set_max(tasks_count())
                --
                if Options.jailed then
                    Jail.create()
                end
                if not Action.perform_upgrades() then
                    if Options.hide_build then
                        -- shell_pipe ("cat > /dev/tty", BUILDLOG) -- use read and write to copy the file to STDOUT XXX
                    end
                    fail("Port upgrade failed.")
                end
                if Options.jailed then
                    Jail.destroy()
                end
                Progress.clear()
                if Options.repo_mode then
                    Action.perform_repo_update()
                else
                    -- XXX fold into perform_upgrades()???
                    -- new action verb required???
                    -- or just a plain install from package???)
                    --[[
                    if #DELAYED_INSTALL_LIST > 0 then -- NYI to be implemented in a different way
                        PARAM.phase = "install"
                        perform_delayed_installations()
                    end
                    --]]
                end
            end
            if tasks_count() == 0 then
                Msg.show {start = true, "All requested actions have been completed"}
            end
            Progress.clear()
            PARAM.phase = ""
        end
    end
    return true
end

local function plan()

end

return {add_missing_deps = add_missing_deps, sort_list = sort_list, execute = execute, plan = plan}
