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
-- get list of installed (if any) or available flavors
local PORTS_CACHE = {}

-- ----------------------------------------------------------------------------------
-- get list of installed (if any) or available flavors
local function flavors_get (portdir)
   local port = PORTS_CACHE[portdir]
   if port then
      local flavors = port.flavors
      if flavors ~= nil then
	 return flavors
      end
   end
   local response = origin:port_var {"FLAVORS"}
   if response then
      flavors = split_words (response)
   else
      flavors = false
   end
   PORTS_CACHE[port].flavors = flavors
   return flavors
end

--
local function __index (self, k)
   --[[
   local function __port_vars (self, k)
      local function set_field (field, v)
	 if v == "" then v = false end
	 self[field] = v
      end
      local t = PkgDb.query {table = true, "%q\n%k\n%a\n%#r", self.name_base}
      set_field ("abi", t[1])
      set_field ("is_locked", t[2] == "1")
      set_field ("is_automatic", t[3] == "1")
      set_field ("num_depending", tonumber (t[4]))
      return self[k]
   end
   --]]

   local dispatch = {
      flavors = flavors_get,
   }

   local w = rawget (self.__class, k)
   if w == nil then
      TRACE ("INDEX(d)", self, k)
      rawset (self, k, false)
      local f = dispatch[k]
      if f then
	 w = f (self, k)
	 if w then
	    rawset (self, k, w)
	 else
	    w = false
	 end
      else
	 error ("illegal field requested: Port." .. k)
      end
      TRACE ("INDEX(d)->", self, k, w)
   end
   return w
end

-- create new Package object or return existing one for given name
local function new (port, name)
   --local TRACE = print -- TESTING
   assert (type (name) == "string", "Port:new (" .. type (name) .. ")")
   if name then
      local P = PORTS_CACHE[name]
      if not P then
	 P = {name = name}
	 P.__class = port
	 port.__index = __index
	 port.__tostring = function (self)
	    return self.name
	 end
	 --port.__eq = function (a, b) return a.name == b.name end
	 setmetatable (P, port)
	 PORTS_CACHE[name] = P
	 TRACE ("NEW Port", name)
      else
	 TRACE ("NEW Port", name, "(cached)")
      end
      return P
   end
   return nil
end

-- ----------------------------------------------------------------------------------
return {
   name = false,
   new = new,
   origin = false,
   --dir = dir,
   --path = path,
   --flavor = flavor,
   --flavors = flavors,
}
