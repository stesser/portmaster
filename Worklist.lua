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
-- locate item position in list
local function list_find (list, origin)
   for i, v in ipairs (list) do
      if v == origin then
	 return i
      end
   end
end

-- debug function that prints the contents of the list
local function list_dump (list)
   for i, v in ipairs (list) do
      print (v)
   end
end

-- WORKLIST is an ordered list of unique items to be processed from left to right
WORKLIST = {} -- GLOBAL

-- remove item from worklist if found
local function remove (origin)
   local i = list_find (WORKLIST, origin.name)
   if i then
      table.remove (WORKLIST, i)
      Progress.num_decr ("actions")
      TRACE ("worklist_remove", origin.name)
   end
end

-- add new entry at the end of WORKLIST (with check for duplicates)
local function add (origin)
   if not list_find (WORKLIST, origin.name) then
      table.insert (WORKLIST, origin.name)
      Progress.num_incr ("actions")
      TRACE ("worklist_add", origin.name)
   else
      TRACE ("worklist_add", origin.name, "(duplicate request is ignored)")
   end
end

-- register for installation after all ports have been built
DELAYED_INSTALL_LIST = {} -- GLOBAL

local function remove_delayedlist (origin)
   local i = list_find (DELAYED_INSTALL_LIST, origin.name)
   if i then
      table.remove (DELAYED_INSTALL_LIST, i)
      Progress.num_decr ("delayed")
      TRACE ("delayedlist_remove", origin.name)
   end
end

-- add new entry at the end of DELAYED_INSTALL_LIST (with check for duplicates)
local function add_delayedlist (origin)
   if not list_find (DELAYED_INSTALL_LIST, origin.name) then
      table.insert (DELAYED_INSTALL_LIST, origin.name)
      Progress.num_incr ("delayed")
      TRACE ("delayedlist_add", origin.name)
   else
      TRACE ("delayedlist_add", origin.name, "(duplicate request is ignored)")
   end
end

-- 
return {
   add = add,
   remove = remove,
   add_delayedlist = add_delayedlist,
   remove_delayedlist = remove_delayedlist,
}
