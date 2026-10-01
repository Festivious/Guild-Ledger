-- WoW event wiring for the looting record: every loot window, and every craft. Deliberately thin:
-- every decision lives in LootRules, which is pure and tested. This file only translates events
-- into calls.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 3. Who owns which
-- looting trigger, so nothing counts twice:
--   LOOT_OPENED     here: the window and each item's source are noted. Events.lua still records the
--                   mob's drops from the same window (what DROPPED), except for a skinned corpse,
--                   which it is told to leave alone (ns.isSkinning).
--   CHAT_MSG_LOOT   here only: Blizzard's receive and create lines.
--   LOOT_CLOSED     here: the window settles a moment later. Events.lua also closes its kill.
--   settling        gather window -> Gathered facts; corpse window -> the kill's received counts
--                   (ns.killLog); anything else -> nothing yet.
-- The other captures (kills, spawns, deaths, quests, vendors) are untouched.
local _, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema, GUID, Patterns = GBA.Schema, ns.GUID, ns.Patterns
local rules = ns.LootRules.new()
local buffer, episodes = ns.buffer, ns.episodes

-- Whether the loot window about to open is a skinned corpse. Herbs and ore come from nodes, which
-- the corpse loot capture never mistakes for a kill; a skinned corpse it would.
function ns.isSkinning()
    return rules:skinning(GetTime())
end

local function itemIDFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function classOf(itemID)
    if not (itemID and GetItemInfoInstant) then return nil end
    return select(6, GetItemInfoInstant(itemID))
end

local function lootSlots()
    local slots = {}
    local n = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, n do
        local itemID = itemIDFromLink(GetLootSlotLink and GetLootSlotLink(slot))
        local ok, guid = false, nil
        if GetLootSourceInfo then ok, guid = pcall(GetLootSourceInfo, slot) end
        if itemID and ok and type(guid) == "string" then
            slots[#slots + 1] = {
                itemID = itemID, sourceGUID = guid, sourceType = guid:match("^(%a+)%-"),
                sourceID = GUID.npcID(guid), classID = classOf(itemID),
            }
        end
    end
    return slots
end

-- "text" against Blizzard's own format strings, the multiple form first: the single form would
-- also match "[item]x3" and lose the count.
local function received(text, single, multiple)
    local m = multiple and Patterns.match(text, multiple)
    if m then return itemIDFromLink(m[1]), tonumber(m[2]) end
    m = single and Patterns.match(text, single)
    if m then return itemIDFromLink(m[1]), 1 end
    return nil
end

-- Written field by field, so tests/test_coverage.lua can read every declared field off the
-- source and prove it is set.
local function recordGathered(g)
    local context = ns.playerContext and ns.playerContext() or {}
    buffer:add(Schema.factType.gathered, Schema.toArray(Schema.factType.gathered, {
        kind = g.kind,
        sourceID = g.sourceID,
        itemID = g.itemID,
        quantity = g.quantity,
        mapID = context.mapID,
        coord = context.coord,
        observerLevel = context.observerLevel,
        lootIndex = g.lootIndex,
    }), episodes:current(), time())
end

local function recordCrafted(c)
    local context = ns.playerContext and ns.playerContext() or {}
    buffer:add(Schema.factType.crafted, Schema.toArray(Schema.factType.crafted, {
        spellID = c.spellID,
        itemID = c.itemID,
        quantity = c.quantity,
        mapID = context.mapID,
        coord = context.coord,
        observerLevel = context.observerLevel,
    }), episodes:current(), time())
end

-- What a settled window makes.
local function apply(result)
    if not result then return end
    for _, values in ipairs(result.gathered) do recordGathered(values) end
    if result.kind == "corpse" and ns.killLog then
        -- The window's own corpse, by GUID: its drops learn what was taken.
        ns.killLog:markReceived(result.sourceGUID, result.received)
    end
end

-- A closed window settles a moment later, so a receive line trailing the close still counts.
local function settleSoon()
    local function settle() apply(rules:settle(GetTime())) end
    if C_Timer and C_Timer.After then C_Timer.After(ns.LootRules.GRACE + 0.05, settle) else settle() end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and spellID then rules:onCast(spellID, GetTime()) end
    elseif event == "LOOT_OPENED" then
        -- A window still settling from a moment ago is settled now, before this one starts.
        apply(rules:onLootWindow(lootSlots(), GetTime()))
    elseif event == "LOOT_CLOSED" then
        rules:onLootClosed(GetTime())
        settleSoon()
    elseif event == "CHAT_MSG_LOOT" then
        local text, now = ..., GetTime()
        local itemID, count = received(text, LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE)
        if itemID then
            -- Collected; written when the window closes and settles.
            rules:onReceived(itemID, count, now)
            return
        end
        itemID, count = received(text, LOOT_ITEM_CREATED_SELF, LOOT_ITEM_CREATED_SELF_MULTIPLE)
        if itemID then
            local values = rules:onCreated(itemID, count, now)
            if values then recordCrafted(values) end
        end
    end
end)
