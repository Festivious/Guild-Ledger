-- What a combat log event means for the character, blow by blow. Pure, no WoW API use.
--
-- Spec: docs/superpowers/specs/2026-09-27-blow-by-blow-fights-design.md. Events.lua hears the
-- combat log and hands each event here as the arguments CombatLogGetCurrentEventInfo() returned,
-- from the subevent on. What comes back is a blow (a hit, a miss or a heal, either way) or an aura
-- change, as named values, or nil for everything that is not about the character.
--
-- Spell ids are real numbers on this client: casts captured in game carried 21084 (Seal of
-- Righteousness), 20271 (Judgement) and 75 (Auto Shot), never 0.
local _, ns = ...
if ns and ns.standDown then return end

local Blows = {}

local DIR = { dealt = 1, taken = 2, healDealt = 3, healTaken = 4 }
local RESULT = { hit = 0, crit = 1, miss = 2, dodge = 3, parry = 4, block = 5, resist = 6,
    absorb = 7, immune = 8, evade = 9 }
local MISS = { MISS = RESULT.miss, DODGE = RESULT.dodge, PARRY = RESULT.parry, BLOCK = RESULT.block,
    RESIST = RESULT.resist, ABSORB = RESULT.absorb, IMMUNE = RESULT.immune, EVADE = RESULT.evade,
    DEFLECT = RESULT.miss, REFLECT = RESULT.resist }

-- The other party's npc id from a GUID ("Creature-0-...-<npc>-<spawn>"); 0 for a player or none.
local function npcOf(guid)
    if type(guid) ~= "string" then return 0 end
    local kind, npc = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" or kind == "Pet" then return tonumber(npc) or 0 end
    return 0
end
Blows.npcOf = npcOf

-- Mob numbers (schema 25): each creature the character deals with in a session gets the next
-- number, 1, 2, 3, the first time it is seen, from its whole GUID (the spawn part tells two of the
-- same kind apart). A number, not the GUID: one byte on the wire against forty, and the GUID's
-- server and zone parts mean nothing to a reader. A new session starts again from 1.
local Mobs = {}
Mobs.__index = Mobs

function Blows.newMobs()
    return setmetatable({ session = nil, byGUID = {}, count = 0 }, Mobs)
end

local function creature(guid)
    if type(guid) ~= "string" then return false end
    local kind = guid:match("^(%a+)%-")
    return kind == "Creature" or kind == "Vehicle"
end

function Mobs:reset(sessionID)
    if self.session ~= sessionID then self.session, self.byGUID, self.count = sessionID, {}, 0 end
end

-- The mob's number, giving it the next one if it is new. nil for players, pets and nothing.
function Mobs:number(guid, sessionID)
    if not creature(guid) then return nil end
    self:reset(sessionID)
    local n = self.byGUID[guid]
    if not n then
        self.count = self.count + 1
        n = self.count
        self.byGUID[guid] = n
    end
    return n
end

-- The mob's number only if it already has one: a death in range is not a mob we dealt with.
function Mobs:known(guid, sessionID)
    if self.session ~= sessionID then return nil end
    return self.byGUID[guid]
end

local function direction(source, dest, me)
    if dest == me then return DIR.taken end
    if source == me then return DIR.dealt end
    return nil
end

-- subevent, sourceGUID, destGUID: from the log. me: the player's GUID; target: their target's.
-- ...: the event's own values after destRaidFlags (the spell prefix and the suffix).
-- Returns "blow", values | "aura", values | nil. values.guid is the other party's GUID, for the
-- caller to number (Mobs); it is not a schema field and never stored.
function Blows.read(subevent, sourceGUID, destGUID, me, target, ...)
    if type(subevent) ~= "string" or (sourceGUID ~= me and destGUID ~= me and destGUID ~= target) then return nil end
    local other = sourceGUID == me and destGUID or sourceGUID
    local function out(kind, values) values.guid = values.guid or other; return kind, values end

    if subevent == "SWING_DAMAGE" then
        local dir = direction(sourceGUID, destGUID, me)
        if not dir then return nil end
        local amount, overkill, _, _, _, absorbed, critical = ...
        return out("blow", { dir = dir, spellID = 0, npcID = npcOf(other), amount = amount or 0,
            result = critical and RESULT.crit or RESULT.hit, absorbed = absorbed, overkill = (overkill or 0) > 0 and overkill or nil })
    end

    if subevent == "SWING_MISSED" then
        local dir = direction(sourceGUID, destGUID, me)
        if not dir then return nil end
        local missType, _, amountMissed = ...
        return out("blow", { dir = dir, spellID = 0, npcID = npcOf(other), amount = 0,
            result = MISS[missType] or RESULT.miss, absorbed = missType == "ABSORB" and amountMissed or nil })
    end

    if subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE" or subevent == "RANGE_DAMAGE" then
        local dir = direction(sourceGUID, destGUID, me)
        if not dir then return nil end
        local spellID, _, _, amount, overkill, _, _, _, absorbed, critical = ...
        return out("blow", { dir = dir, spellID = spellID or 0, npcID = npcOf(other), amount = amount or 0,
            result = critical and RESULT.crit or RESULT.hit, absorbed = absorbed, overkill = (overkill or 0) > 0 and overkill or nil })
    end

    if subevent == "SPELL_MISSED" or subevent == "SPELL_PERIODIC_MISSED" or subevent == "RANGE_MISSED" then
        local dir = direction(sourceGUID, destGUID, me)
        if not dir then return nil end
        local spellID, _, _, missType, _, amountMissed = ...
        return out("blow", { dir = dir, spellID = spellID or 0, npcID = npcOf(other), amount = 0,
            result = MISS[missType] or RESULT.miss, absorbed = missType == "ABSORB" and amountMissed or nil })
    end

    if subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        local dir
        if destGUID == me then dir = DIR.healTaken elseif sourceGUID == me then dir = DIR.healDealt else return nil end
        local spellID, _, _, amount, overhealing, absorbed, critical = ...
        return out("blow", { dir = dir, spellID = spellID or 0, npcID = npcOf(dir == DIR.healTaken and sourceGUID or destGUID),
            amount = math.max(0, (amount or 0) - (overhealing or 0)), result = critical and RESULT.crit or RESULT.hit,
            absorbed = absorbed, overkill = nil })
    end

    if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REMOVED" then
        local who
        if destGUID == me then who = 1 elseif destGUID == target then who = 2 else return nil end
        local spellID = ...
        return out("aura", { who = who, spellID = spellID or 0, change = subevent == "SPELL_AURA_APPLIED" and 1 or 2,
            npcID = who == 2 and npcOf(destGUID) or nil,
            -- On the target, the mob is the target; on the character, whoever put it there.
            guid = who == 2 and destGUID or sourceGUID })
    end

    return nil
end

-- WoW's facing is radians from north, counter-clockwise. The analytics draw on the map, where 0 is
-- east and angles turn clockwise (y runs down), so north is 270 and west 180.
function Blows.mapFacing(radians)
    if type(radians) ~= "number" then return nil end
    return math.floor(270 - math.deg(radians) + 0.5) % 360
end

if ns then ns.Blows = Blows end
return Blows
