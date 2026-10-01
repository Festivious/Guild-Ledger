-- Health and power over time. Pure, no WoW API use.
--
-- This is what turns a replay from a moving dot into a story. An officer reviewing a
-- levelling player wants to see the near-death moments, and the long flat stretches at
-- low mana that mean the player is sitting and drinking rather than pulling.
--
-- Percentages rather than raw values: a level 12 and a level 40 are then directly
-- comparable, which is the whole point when coaching across a guild.
local _, ns = ...
if ns and ns.standDown then return end

local Vitals = {}
Vitals.__index = Vitals

-- Recording every tick would be mostly duplicates. A meaningful swing, or a quiet
-- heartbeat so flat stretches are still visible, captures the shape at a fraction of it.
Vitals.PRESETS = {
    normal = { minDelta = 10, maxInterval = 30 },
    replay = { minDelta = 3, maxInterval = 2 },
}

function Vitals.new(opts)
    opts = opts or {}
    return setmetatable({
        minDelta = opts.minDelta or Vitals.PRESETS.normal.minDelta,
        maxInterval = opts.maxInterval or Vitals.PRESETS.normal.maxInterval,
        lastHealth = nil,
        lastPower = nil,
        lastCombat = nil,
        lastTS = nil,
    }, Vitals)
end

function Vitals:configure(preset)
    local settings = Vitals.PRESETS[preset]
    if not settings then return false end
    self.minDelta = settings.minDelta
    self.maxInterval = settings.maxInterval
    return true
end

function Vitals:shouldRecord(healthPct, powerPct, inCombat, ts)
    if type(healthPct) ~= "number" then return false end
    if self.lastHealth == nil then return true end

    -- Entering or leaving combat is always worth a sample: it is the boundary that makes
    -- the surrounding numbers mean something.
    if inCombat ~= self.lastCombat then return true end

    if math.abs(healthPct - self.lastHealth) >= self.minDelta then return true end
    if powerPct and self.lastPower
        and math.abs(powerPct - self.lastPower) >= self.minDelta then return true end
    if self.lastTS and (ts - self.lastTS) >= self.maxInterval then return true end

    return false
end

function Vitals:accept(healthPct, powerPct, inCombat, ts)
    self.lastHealth, self.lastPower = healthPct, powerPct
    self.lastCombat, self.lastTS = inCombat, ts
end

function Vitals:offer(healthPct, powerPct, inCombat, ts)
    if not self:shouldRecord(healthPct, powerPct, inCombat, ts) then return false end
    self:accept(healthPct, powerPct, inCombat, ts)
    return true
end

if ns then ns.Vitals = Vitals end
return Vitals
