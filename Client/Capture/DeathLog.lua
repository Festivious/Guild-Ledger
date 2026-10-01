-- What killed the player. Pure state machine, no WoW API use.
--
-- The killing blow is not knowable from the death event itself: UNIT_DIED says only that
-- you died. So recent incoming damage is tracked, and the death claims the most recent
-- of it. Damage older than the window is not treated as the cause - dying to a lingering
-- effect long after a mob stopped hitting you should report "unknown", not blame the last
-- thing that happened to touch you.
--
-- Environmental deaths matter as much as mobs here. In Hardcore, falls and drowning end
-- as many characters as creatures do, and no existing database records either.
local _, ns = ...
if ns and ns.standDown then return end

local DeathLog = {}
DeathLog.__index = DeathLog

-- A killing blow lands within a couple of seconds of the death. Ten gives room for a
-- slow client without reaching back into an unrelated fight.
local DEFAULT_WINDOW = 10

function DeathLog.new(opts)
    opts = opts or {}
    return setmetatable({
        window = opts.window or DEFAULT_WINDOW,
        lastHit = nil,
        deaths = {},
    }, DeathLog)
end

-- info: { npcID, spellID, amount, environment }
function DeathLog:noteDamage(info, ts)
    if type(info) ~= "table" then return end
    self.lastHit = {
        npcID = info.npcID,
        spellID = info.spellID,
        amount = info.amount,
        environment = info.environment,
        ts = ts,
    }
end

-- Returns the death record, or nil if this was not a usable death.
function DeathLog:recordDeath(ts, context)
    context = context or {}

    local hit = self.lastHit
    local attributable = hit and (ts - (hit.ts or 0)) <= self.window

    local death = {
        ts = ts,
        mapID = context.mapID,
        coord = context.coord,
        observerLevel = context.observerLevel,
        groupSize = context.groupSize,
        killerNpcID = attributable and hit.npcID or nil,
        killerSpellID = attributable and hit.spellID or nil,
        environment = attributable and hit.environment or nil,
        killingBlow = attributable and hit.amount or nil,
    }

    self.deaths[#self.deaths + 1] = death
    -- The blow is spent: a later death must not inherit this one's killer.
    self.lastHit = nil
    return death
end

function DeathLog:count()
    return #self.deaths
end

function DeathLog:drain()
    local deaths = self.deaths
    self.deaths = {}
    return deaths
end

function DeathLog:last()
    return self.deaths[#self.deaths]
end

if ns then ns.DeathLog = DeathLog end
return DeathLog
