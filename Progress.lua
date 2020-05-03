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
local Msg = require("Msg")

-- ----------------------------------------------------------------------------------
local PROGRESS = {count = 0, max = nil, state = nil}

-- set the upper limit for counter ranges
local function set_max(max)
    PROGRESS.count = 0
    PROGRESS.max = max
    PROGRESS.state = ""
end

-- increment the progress counter
local function incr()
    PROGRESS.count = PROGRESS.count + 1
    PROGRESS.state = PROGRESS.count
    if PROGRESS.max then
        PROGRESS.state = "[" .. PROGRESS.state .. "/" .. PROGRESS.max .. "]"
    else
        PROGRESS.state = "[" .. PROGRESS.state .. "]"
    end
end

-- reset the upper limit and clear the window title
local function clear()
    set_max(nil)
    Msg.title_set("")
end

-- print a progress message and display it in the terminal window
local function show(...)
    Msg.show {...}
    -- title_set (PROGRESS.state, ...)
end

-- increment counter and print a header line for new task
local function show_task(...)
    incr()
    TRACE("SHOW_TASK", ...)
    Msg.show {PROGRESS.state, ...} -- or better msg_start () ???
    Msg.title_set(PROGRESS.state, ...)
end

return {
    clear = clear,
    -- num_incr = incr,
    -- num_decr = decr,
    show = show,
    show_task = show_task,
    -- list = list,
    set_max = set_max
}
