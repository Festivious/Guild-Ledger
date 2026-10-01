-- Details! — combat aggregation. The richest spoke: it has already done per-actor,
-- per-spell work we would otherwise parse ourselves.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local Details = {
    name = "Details",
    -- realversion 172 is the build that ships CreateEventListener and the
    -- COMBAT_PLAYER_LEAVE payload shape we rely on.
    minVersion = 172,
}

function Details.detect(env)
    local d = env.global("Details")
    if type(d) ~= "table" then return false end
    local version = Adapter.field(d, "realversion")
    if version == nil then return false end
    return true, version
end

-- The supported headless path: returns an object with Enabled and __enabled already set
-- plus RegisterEvent. Dispatch is gated on BOTH flags, so a hand-rolled table silently
-- never fires (functions/events.lua:361, :406).
function Details.createListener(env)
    local d = env.global("Details")
    local factory = Adapter.field(d, "CreateEventListener")
    if type(factory) ~= "function" then return nil end
    return factory(d)
end

-- COMBAT_PLAYER_LEAVE also fires for invalid combats that never enter the segment table
-- (too short, no data). Those must be filtered or the corpus fills with junk fights.
function Details.isUsableCombat(env, combat)
    if type(combat) ~= "table" then return false end
    local getTime = Adapter.field(combat, "GetCombatTime")
    if type(getTime) ~= "function" then return false end
    local elapsed = Adapter.tryCall(getTime, combat)
    if type(elapsed) ~= "number" or elapsed <= 0 then return false end
    return true
end

if ns and ns.Spokes then ns.Spokes:register(Details) end
return Details
