-- The minimap's subzone name, as it changes. Pure, no WoW API use.
--
-- GetSubZoneText() is what the minimap shows: "Goldshire", "Fargodeep Mine". It is the name a
-- player would give the place they were in, so it is what names a playing field and a play in the
-- analytics frame. Written only when it changes, so a session holds a handful of these.
--
-- An empty name is a change too: it means the character walked out of the named place, and
-- without it everything afterwards would still read as Goldshire.
local _, ns = ...
if ns and ns.standDown then return end

local Subzone = {}
Subzone.__index = Subzone

function Subzone.new()
    return setmetatable({ last = nil }, Subzone)
end

-- Whether this name is worth writing. A nil name (the API not answering) is never a change:
-- recording "left the subzone" because a call failed would be a lie.
function Subzone:offer(name)
    if type(name) ~= "string" then return false end
    if name == self.last then return false end
    self.last = name
    return true
end

-- A new session writes its first name again, whatever the last session ended on.
function Subzone:reset()
    self.last = nil
end

if ns then ns.Subzone = Subzone end
return Subzone
