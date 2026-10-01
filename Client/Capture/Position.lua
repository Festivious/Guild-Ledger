-- Position sampling. The decision of WHETHER to record is pure and tested; the polling
-- timer is the only part that touches WoW.
--
-- Standing still must not emit a thousand identical rows, but time spent in one place is
-- itself meaningful for heat maps, so a stationary player still records occasionally.
local _, ns = ...
if ns and ns.standDown then return end

local Sampler = {}
Sampler.__index = Sampler

local DEFAULTS = {
    minDistance = 0.004,  -- normalized map units, roughly a few yards
    maxInterval = 30,     -- seconds; a stationary player still leaves a trace
}

-- Replay needs a path that can be interpolated, which means a sample about every second
-- whether the player moved or not. Normal capture only wants enough to draw a heat map.
Sampler.PRESETS = {
    normal = { minDistance = 0.004, maxInterval = 30 },
    replay = { minDistance = 0.0005, maxInterval = 1 },
}

function Sampler.new(opts)
    opts = opts or {}
    return setmetatable({
        minDistance = opts.minDistance or DEFAULTS.minDistance,
        maxInterval = opts.maxInterval or DEFAULTS.maxInterval,
        lastMapID = nil,
        lastX = nil,
        lastY = nil,
        lastTS = nil,
    }, Sampler)
end

-- Switches cadence without losing the last known position, so a mode change mid-session
-- does not produce a spurious sample or a gap.
function Sampler:configure(preset)
    local settings = Sampler.PRESETS[preset]
    if not settings then return false end
    self.minDistance = settings.minDistance
    self.maxInterval = settings.maxInterval
    return true
end

-- Squared distance keeps this allocation-free and avoids a square root on the hot path.
local function movedFarEnough(self, x, y)
    if self.lastX == nil then return true end
    local dx, dy = x - self.lastX, y - self.lastY
    return (dx * dx + dy * dy) >= (self.minDistance * self.minDistance)
end

function Sampler:shouldRecord(mapID, x, y, ts)
    if mapID == nil or x == nil or y == nil then return false end
    if mapID ~= self.lastMapID then return true end
    if movedFarEnough(self, x, y) then return true end
    if self.lastTS and (ts - self.lastTS) >= self.maxInterval then return true end
    return false
end

function Sampler:accept(mapID, x, y, ts)
    self.lastMapID, self.lastX, self.lastY, self.lastTS = mapID, x, y, ts
end

-- Convenience: decide and update in one call.
function Sampler:offer(mapID, x, y, ts)
    if not self:shouldRecord(mapID, x, y, ts) then return false end
    self:accept(mapID, x, y, ts)
    return true
end

if ns then ns.Sampler = Sampler end
return Sampler
