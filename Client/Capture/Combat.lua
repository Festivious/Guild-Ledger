-- Turns a finished Details combat object into spell_effect facts.
--
-- Details has already done the per-actor, per-spell aggregation - hit counts, crit counts,
-- totals - so this only walks its finished tables. Every step is optional: Details' own
-- API.txt says it is incomplete, and MISC containers are created lazily, so a missing
-- field must thin the data rather than break capture.
local _, ns = ...
if ns and ns.standDown then return end

local LIB = LibStub and LibStub("LibGuildLedger-1.0", true)
local Adapter = (LIB and LIB.Adapter) or require("Spokes.Adapter")

local Combat = {}

Combat.ATTRIBUTE_DAMAGE = 1
Combat.ATTRIBUTE_HEAL = 2

local field, tryCall = Adapter.field, Adapter.tryCall

local function actorFor(combat, attribute, actorName)
    local getContainer = field(combat, "GetContainer")
    if type(getContainer) ~= "function" then return nil end

    local container = tryCall(getContainer, combat, attribute)
    local getActor = field(container, "GetActor")
    if type(getActor) ~= "function" then return nil end

    return tryCall(getActor, container, actorName)
end

-- Returns { {spellID, amount, hits, crits}, ... } for one actor, or an empty list.
function Combat.extractSpells(combat, actorName, attribute)
    local out = {}
    local actor = actorFor(combat, attribute or Combat.ATTRIBUTE_DAMAGE, actorName)
    if not actor then return out end

    local getSpellList = field(actor, "GetSpellList")
    if type(getSpellList) ~= "function" then return out end

    local spells = tryCall(getSpellList, actor)
    if type(spells) ~= "table" then return out end

    for spellID, spell in pairs(spells) do
        local id = tonumber(spellID) or tonumber(field(spell, "id"))
        if id then
            local crits = tonumber(field(spell, "c_amt")) or 0
            local normal = tonumber(field(spell, "n_amt")) or 0
            local counter = tonumber(field(spell, "counter")) or (normal + crits)
            out[#out + 1] = {
                spellID = id,
                amount = tonumber(field(spell, "total")) or 0,
                hits = counter,
                crits = crits,
            }
        end
    end
    return out
end

function Combat.duration(combat)
    local getTime = field(combat, "GetCombatTime")
    if type(getTime) ~= "function" then return nil end
    return tonumber(tryCall(getTime, combat))
end

-- COMBAT_PLAYER_LEAVE also fires for combats that never entered the segment table.
function Combat.isUsable(combat)
    local elapsed = Combat.duration(combat)
    return type(elapsed) == "number" and elapsed > 0
end

if ns then ns.Combat = Combat end
return Combat
