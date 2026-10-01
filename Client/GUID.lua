-- Unit GUID parsing. No WoW API use.
--
-- Classic Era creature GUIDs look like:
--   Creature-0-4442-0-25-448-0000123456
--            1 2    3 4  5   6
-- The npcID is the 6th dash-delimited field. The trailing field is the spawn instance,
-- so two of the same mob differ there and must NOT be treated as the same corpse.
--
-- There is deliberately no memoization. An earlier version cached parsed GUIDs and a real
-- session measured 212 entries at a 0% hit rate: corpse GUIDs are unique per spawn and we
-- parse each one once, on UNIT_DIED, so the cache was an unbounded leak that never saved
-- a single parse. Details caches this profitably only because it re-parses the same GUID
-- on every damage event; we never do.
local _, ns = ...
if ns and ns.standDown then return end

local GUID = {}

local NPC_TYPES = { Creature = true, Vehicle = true, Pet = true, GameObject = true }

local parsed, rejected = 0, 0

function GUID.npcID(guid)
    if type(guid) ~= "string" then
        rejected = rejected + 1
        return nil
    end

    local unitType = guid:match("^(%a+)%-")
    if not unitType or not NPC_TYPES[unitType] then
        rejected = rejected + 1
        return nil
    end

    local id = tonumber(guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
    if id then parsed = parsed + 1 else rejected = rejected + 1 end
    return id
end

function GUID.resetStats()
    parsed, rejected = 0, 0
end

function GUID.stats()
    return { parsed = parsed, rejected = rejected }
end

if ns then ns.GUID = GUID end
return GUID
