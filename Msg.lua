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
local Msg = {
   level = 0,
   at_start = true,
   empty_line = true,
   doprompt = false,
   sep1 = "# -----\t",
   sep2 = "#\t",
   sepabort = "# !!!!!\t",
   sepprompt = "#   >>>\t",
}
Msg.sep = Msg.sep1

-- print continuation line
local function cont (level, ...)
   if level <= Msg.level then
      local lines = split_lines (table.concat ({...}, " "))
      if lines then
	 -- extra blank line if not a continuation and not following a blank line anyway
	 if not (Msg.empty_line or not Msg.at_start) then
	    stdout:write ("\n")
	    Msg.empty_line = true
	 end
	 -- print lines prefixed with SEP
	 local line
	 for i, line in ipairs (lines) do
	    if not line or line == "" then
	       if not Msg.empty_line then
		  stdout:write ("\n")
		  Msg.empty_line = true
	       end
	    else
	       Msg.empty_line = false
	       if Msg.doprompt then
		  -- no newline after prompt
		  stdout:write (Msg.sep, line)
	       else
		  stdout:write (Msg.sep, line, "\n")
		  Msg.sep = Msg.sep2
	       end
	    end
	    Msg.at_start = false
	 end
	 -- reset to default prefix after reading user input
	 if Msg.doprompt then
	    Msg.sep = Msg.sep1
	    Msg.at_start = true
	    Msg.doprompt = false
	 end
      end
      stdout:flush ()
   end
end

-- print message with separator for new message section
local function start (level, ...)
   if level <= Msg.level then
      Msg.at_start = true
      Msg.sep = Msg.sep1
      cont (level, ...)
   end
end

-- print abort message at level 0
local function abort (...)
   Msg.at_start = true
   Msg.sep = "\n" .. Msg.sepabort
   cont (0, ...)
end

-- print message without indentation or other changes
local function verbatim (level, ...)
   if level <= Msg.level then
      stdout.write (...)
   end
end

-- print a prompt to request user input
local function prompt (...)
   Msg.doprompt = true
   Msg.sep = Msg.sepprompt
   Msg.at_start = true
   cont (0, ...)
   Msg.doprompt = false
   Msg.sep = Msg.sep2
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
      Msg.cont (0)
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
	    Msg.start (0)
	    Msg.cont (0, "Post-install message for", pkgname .. ":")
	    Msg.cont (0)
	    Msg.verbatim (0, table.concat (pkgmsg, "\n", 2))
	 end
      end
      Msg.start (0, "The following actions have been performed:")
      for i, line in ipairs (SUCCESS_MSGS) do
	 Msg.cont (0, line)
      end
      if tasks_count () == 0 then
	 Msg.start (0, "All requested actions have been completed")
      end
   end
   PKGMSG = nil -- required ???
end

--
function msg (args)
   local level = args.level or 0
   if args.verbatim then
      verbatim (level, table.unpack (args))
   elseif args.start then
      start (level, table.unpack (args))
   elseif args.prompt then
      prompt (level, table.unpack (args))
   else
      cont (level, table.unpack (args))
   end
end

-- ----------------------------------------------------------------------------------
Msg.start = start
Msg.cont = cont
Msg.checking = checking
Msg.title_set = title_set
Msg.success_add = success_add
Msg.display = display
Msg.prompt = prompt

return Msg
