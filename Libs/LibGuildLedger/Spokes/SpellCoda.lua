-- SpellCoda — vanilla spell rank grouping.
--
-- Caveat: it only builds the LOGGED-IN class's table, so it can resolve the observer's
-- own casts but never all nine classes. A decoder needing every class must use a
-- flattened table shipped in Core instead.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local SpellCoda = { name = "SpellCoda" }

function SpellCoda.detect(env)
    local sc = env.global("SpellCoda")
    if type(sc) ~= "table" then return false end
    local version = env.metadata("SpellCoda", "Version")
    return true, version
end

-- Rank grouping in one lookup: base_id is the Rank 1 spellID, rank is which rank this is.
function SpellCoda.spellRank(env, spellID)
    local sc = env.global("SpellCoda")
    local spells = Adapter.field(sc, "spells")
    local spell = Adapter.field(spells, spellID)
    if type(spell) ~= "table" then return nil end
    return { baseID = Adapter.field(spell, "base_id"), rank = Adapter.field(spell, "rank") }
end

if ns and ns.Spokes then ns.Spokes:register(SpellCoda) end
return SpellCoda
