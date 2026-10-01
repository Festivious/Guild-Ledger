-- MobInfo2 — seed data only.
--
-- It is the only prior art that records the empty-loot denominator, so an existing
-- MobInfoDB is worth importing once. It has no public API, and its records are keyed by
-- "mobName:mobLevel" rather than npcID, so imported rows are locale-bound and must be
-- marked as such rather than mixed with our own npcID-keyed observations.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local MobInfo2 = { name = "MobInfo2" }

function MobInfo2.detect(env)
    if type(env.global("MobInfoDB")) ~= "table" then return false end
    local version = env.metadata("MobInfo2", "Version")
    return true, version
end

function MobInfo2.seedData(env)
    return env.global("MobInfoDB")
end

function MobInfo2.entryCount(env)
    local db = env.global("MobInfoDB")
    if type(db) ~= "table" then return nil end
    local count = 0
    for _ in pairs(db) do count = count + 1 end
    return count
end

if ns and ns.Spokes then ns.Spokes:register(MobInfo2) end
return MobInfo2
