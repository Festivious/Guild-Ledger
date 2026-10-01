-- Snapshots Details' finished combat segments.
--
-- Details keeps only about 25 segments and wipes all history on every version bump, so
-- the snapshot must happen at segment close rather than by querying history later.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema = GBA.Schema
local Combat, episodes, buffer = ns.Combat, ns.episodes, ns.buffer

local listener

local function onCombatEnd(_, combatObject)
    -- COMBAT_PLAYER_LEAVE also fires for invalid combats that never entered the segment
    -- table. Those must not reach the corpus.
    if not Combat.isUsable(combatObject) then return end

    local playerName = UnitName("player")
    local spells = Combat.extractSpells(combatObject, playerName)
    if #spells == 0 then return end

    local now = time()
    local episode = episodes:current()
    for _, spell in ipairs(spells) do
        local values = Schema.toArray(Schema.factType.spell_effect, spell)
        buffer:add(Schema.factType.spell_effect, values, episode, now)
    end
end

local function attach()
    listener = GBA.spokes:call("Details", "createListener")
    if not listener then return end
    listener:RegisterEvent("COMBAT_PLAYER_LEAVE", onCombatEnd)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", attach)

