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

-- ----------------------------------------------------------------------------------
local State = {
   level = 0,
   at_start = true,
   empty_line = true,
   doprompt = false,
   sep1 = "# -----\t",
   sep2 = "#\t",
   sepabort = "# !!!!!\t",
   sepprompt = "#   >>>\t",
}
State.sep = State.sep1

-- print continuation line
local function cont (level, ...)
   if level <= State.level then
      local lines = split_lines (table.concat ({...}, " "))
      if lines then
	 -- extra blank line if not a continuation and not following a blank line anyway
	 if not (State.empty_line or not State.at_start) then
	    stdout:write ("\n")
	    State.empty_line = true
	 end
	 -- print lines prefixed with SEP
	 local line
	 for i, line in ipairs (lines) do
	    if not line or line == "" then
	       if not State.empty_line then
		  stdout:write ("\n")
		  State.empty_line = true
	       end
	    else
	       State.empty_line = false
	       if State.doprompt then
		  -- no newline after prompt
		  stdout:write (State.sep, line)
	       else
		  stdout:write (State.sep, line, "\n")
		  State.sep = State.sep2
	       end
	    end
	    State.at_start = false
	 end
	 -- reset to default prefix after reading user input
	 if State.doprompt then
	    State.sep = State.sep1
	    State.at_start = true
	    State.doprompt = false
	 end
      end
      stdout:flush ()
   end
end

-- print abort message at level 0
local function abort (...)
   State.at_start = true
   State.sep = "\n" .. State.sepabort
   cont (0, ...)
end

-- set window title 
local function title_set (...)
   if not Options.no_term_title then
      stderr:write ("\x1b]2;" .. table.concat ({...}, " ") .. "\x07")
   end
end

-- add line to success message to display at the end
local SUCCESS_MSGS = {} -- GLOBAL
local PKGMSG = {}

--
function show (args)
   --TRACE ("MSG_SHOW", table.unpack (table.keys (args)), table.unpack (args))
   local level = args.level or 0
   if level <= State.level then
      if args.start then
	 -- print message with separator for new message section
	 State.at_start = true
	 State.sep = State.sep1
      end
      if args.verbatim then
	 -- print message with separator for new message section
	 stdout:write (table.unpack (args))
      else
	 if args.prompt then
	    -- print a prompt to request user input
	    State.doprompt = true
	    State.sep = State.sepprompt
	    State.at_start = true
	 end
	 -- print arguments
	 local lines = split_lines (table.concat (args, " "))
	 if lines then
	    -- extra blank line if not a continuation and not following a blank line anyway
	    if not (State.empty_line or not State.at_start) then
	       stdout:write ("\n")
	       State.empty_line = true
	    end
	    -- print lines prefixed with SEP
	    local line
	    for i, line in ipairs (lines) do
	       if not line or line == "" then
		  if not State.empty_line then
		     stdout:write ("\n")
		     State.empty_line = true
		  end
	       else
		  State.empty_line = false
		  if State.doprompt then
		     -- no newline after prompt
		     stdout:write (State.sep, line)
		  else
		     stdout:write (State.sep, line, "\n")
		     State.sep = State.sep2
		  end
	       end
	       State.at_start = false
	    end
	    -- reset to default prefix after reading user input
	    if State.doprompt then
	       State.sep = State.sep2 -- sep1 ???
	       State.at_start = true
	       State.doprompt = false
	    end
	 end
      end
   end
end

-- ----------------------------------------------------------------------------------
-- 
local function success_add (text, seconds)
   if Options.dry_run then
      return
   end
   if not strpfx (text, "Provide ") then
      table.insert (SUCCESS_MSGS, text)
      if seconds then
	 seconds = "in " .. seconds .. " seconds"
      end
      Progress.show (text, "successfully completed", seconds)
      show {}
   end
end

-- display all package messages that are new or have changed
local function display ()
   local packages = {}
   if Options.repo_mode then
      packages = table.keys (PKGMSG)
   end
   if packages or SUCCESS_MSGS then
      -- preserve current stdout and locally replace by pipe to "more" ???
      for i, pkgname in ipairs (packages) do
	 local pkgmsg = PkgDb.query {table = true, "%M", pkgname} -- tail +2
	 if pkgmsg then
	    show {start = true}
	    show {"Post-install message for", pkgname .. ":"}
	    show {}
	    show {verbatim = true, table.concat (pkgmsg, "\n", 2)}
	 end
      end
      if #SUCCESS_MSGS > 0 then
	 show {start = true, "The following actions have been performed:"}
	 for i, line in ipairs (SUCCESS_MSGS) do
	    show {line}
	 end
	 if tasks_count () == 0 then
	    show {start = true, "All requested actions have been completed"}
	 end
      end
   end
   PKGMSG = nil -- required ???
end

-- ----------------------------------------------------------------------------------
local function incr_level ()
   State.level = State.level + 1
end

local function level ()
   return State.level
end

-- ----------------------------------------------------------------------------------

Msg = {
   checking = checking,
   display = display,
   incr_level = incr_level,
   level = level,
   show = show,
   success_add = success_add,
   title_set = title_set,
}

return Msg
