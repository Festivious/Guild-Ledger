-- Converts harvested KillLog records into wire facts. Pure, no WoW API use.
--
-- One kill produces up to three kinds of fact:
--   kill       - always, carrying the loot outcome so the denominator survives encoding
--   npc_spawn  - the mob was demonstrably standing there, which is spawn evidence
--   loot_drop  - one per item actually looted
local _, ns = ...
if ns and ns.standDown then return end

local LIB = LibStub and LibStub("LibGuildLedger-1.0", true)
local Schema = (LIB and LIB.Schema) or require("Schema")

local KillFacts = {}

local OBSERVED = "observed"

-- Returns an array of { code = factCode, values = positionalArray }.
function KillFacts.convert(kill)
    if type(kill) ~= "table" or type(kill.npcID) ~= "number" then return {} end

    local context = kill.context or {}
    local mapID, coord = context.mapID, context.coord
    local out = {}

    out[#out + 1] = {
        code = Schema.factType.kill,
        values = Schema.toArray(Schema.factType.kill, {
            npcID = kill.npcID,
            mapID = mapID,
            coord = coord,
            observerLevel = context.observerLevel,
            groupSize = context.groupSize,
            lootState = (kill.lootState == OBSERVED)
                and Schema.lootState.observed
                or Schema.lootState.unobserved,
            participated = kill.participated
                and Schema.participation.participated
                or Schema.participation.bystander,
            -- Its number in the session (schema 25), when the character dealt with it.
            mob = context.mob,
        }),
    }

    -- A spawn observation needs a map, but not necessarily a coordinate. Classic Era
    -- instances report no player position, so requiring one would discard every dungeon
    -- spawn we see - and "this mob appears on this map" is real evidence on its own.
    -- Coordinate-less spawns merge into a single per-map bucket, which is the right
    -- granularity for what was actually observed.
    if mapID then
        out[#out + 1] = {
            code = Schema.factType.npc_spawn,
            values = Schema.toArray(Schema.factType.npc_spawn, {
                npcID = kill.npcID, mapID = mapID, coord = coord,
            }),
        }
    end

    for _, item in ipairs(kill.items or {}) do
        if item.itemID then
            out[#out + 1] = {
                code = Schema.factType.loot_drop,
                values = Schema.toArray(Schema.factType.loot_drop, {
                    npcID = kill.npcID,
                    itemID = item.itemID,
                    quantity = item.quantity or 1,
                    mapID = mapID,
                    coord = coord,
                    -- The same context the kill above was stamped with. A drop rate's
                    -- numerator and denominator have to carry the same dimensions or only
                    -- an undimensioned rate is ever computable, and taking both from one
                    -- kill is what guarantees they agree.
                    observerLevel = context.observerLevel,
                    groupSize = context.groupSize,
                    -- How many the player actually took (Blizzard's receive line), 0 if left;
                    -- nil when the window never settled. Quests count this; drop rates count
                    -- quantity, which is what dropped.
                    received = item.received,
                }),
            }
        end
    end

    return out
end

-- Converts a batch and pushes every fact into a buffer. Returns how many were added.
-- A kill is written minutes after it died, once its loot has settled. It keeps the session and
-- fight it died in (context.chain, taken at the death); the episode passed here, the one running
-- at flush time, is only for kills that carry none. Stamped with the flush-time fight, a kill
-- made between two gathers joined whatever fight was on when the flush came, and the last kills
-- of a session landed in the next one.
function KillFacts.flush(kills, buffer, episode, now)
    local added = 0
    for _, kill in ipairs(kills or {}) do
        local chain = (kill.context and kill.context.chain) or episode
        for _, fact in ipairs(KillFacts.convert(kill)) do
            if buffer:add(fact.code, fact.values, chain, kill.ts or now) then
                added = added + 1
            end
        end
    end
    return added
end

if ns then ns.KillFacts = KillFacts end
return KillFacts
