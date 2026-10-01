-- The looting record: what a loot window held, what Blizzard says the player received from it,
-- and what that makes it. Pure, no WoW API use.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 3. Written against what
-- the client actually reported (/gba gatherprobe, 2026-09-25): a Mining cast, then a loot window
-- whose items name their source (GameObject-...-1731 for a Copper Vein), then Blizzard's own
-- "You receive loot: [Copper Ore]" line. A vein swung twice keeps its GUID. A craft is its cast,
-- then "You create: [Linen Bandage]", with the item's link.
--
-- The one rule for every loot window, corpse, node or skinned corpse alike:
--   1. the window opens: note each item and where it came from;
--   2. each "You receive loot" line for one of its items is collected - Blizzard writes it only
--      when the item is really in the bags, "x3" and repeated lines add up;
--   3. the window closes and, a moment later (a line may trail the close), it settles.
-- What settling makes depends on the window, decided when it opened, so nothing counts twice:
--   gather  a gathering cast (any rank) within WINDOW seconds, and the source matches it - a node
--           for herbs and ore, a corpse for skins. Received trade goods become Gathered.
--   corpse  any other window from a creature: the mob's loot. Every item gets a received count
--           (0 when it was left behind) for its drop record; what DROPPED is still the window.
--   other   chests and the rest: received counts only, used by nobody yet.
-- A craft has no window: a cast within CRAFT_WINDOW seconds before "You create".
local _, ns = ...
if ns and ns.standDown then return end

local LootRules = {}
LootRules.__index = LootRules

LootRules.WINDOW = 5
LootRules.CRAFT_WINDOW = 3
-- How long after the close a window waits for trailing receive lines before it settles.
LootRules.GRACE = 0.5
LootRules.MAX_NODES = 200

-- Gathering kind codes, the same as HardQuest.gatherKind.
LootRules.HERB, LootRules.MINE, LootRules.SKIN = 1, 2, 3

-- The gathering casts, every rank. Mining 2575 was seen by the probe; the rest are the same
-- spells' other ranks. A cast not listed here is not a gathering cast.
LootRules.SPELLS = {
    [2366] = 1, [2368] = 1, [3570] = 1, [11993] = 1,      -- Herb Gathering
    [2575] = 2, [2576] = 2, [3564] = 2, [10248] = 2,      -- Mining
    [8613] = 3, [8617] = 3, [8618] = 3, [10768] = 3,      -- Skinning
}

-- A gathered material is a trade good (item class 7): ore, stone, herbs, leather, hide.
LootRules.MATERIAL_CLASS = 7

function LootRules.new()
    return setmetatable({ cast = nil, lastSpell = nil, window = nil, nodes = {}, order = {} }, LootRules)
end

-- Any cast the player finished. Gathering casts open the chance; every cast is remembered as the
-- possible recipe of a craft.
function LootRules:onCast(spellID, now)
    local kind = LootRules.SPELLS[spellID]
    if kind then self.cast = { kind = kind, at = now } end
    self.lastSpell = { spellID = spellID, at = now }
end

function LootRules:gathering(now)
    return self.cast ~= nil and now - self.cast.at <= LootRules.WINDOW
end

-- Whether a window opening now is a skinned corpse, which the corpse loot capture must not count
-- as the mob's drop.
function LootRules:skinning(now)
    return self:gathering(now) and self.cast.kind == LootRules.SKIN
end

local function remember(self, guid)
    self.nodes[guid] = true
    self.order[#self.order + 1] = guid
    if #self.order > LootRules.MAX_NODES then
        self.nodes[table.remove(self.order, 1)] = nil
    end
end

-- Which kind of window these slots make, decided once, as it opens.
local function classify(self, slots, now)
    local first = slots[1]
    if not first then return "other" end
    if self:gathering(now) then
        local kind = self.cast.kind
        local wanted = kind == LootRules.SKIN and "Creature" or "GameObject"
        if first.sourceType == wanted then return "gather", kind end
    end
    if first.sourceType == "Creature" then return "corpse" end
    return "other"
end

-- The loot window opened. `slots` are { itemID, sourceGUID, sourceType ("GameObject" or
-- "Creature"), sourceID, classID }. A window that closed but has not settled yet is settled first,
-- so fast looting loses nothing; what it settles is returned for the caller to write.
function LootRules:onLootWindow(slots, now)
    local earlier = self:settle(now, true)
    slots = slots or {}
    local kind, gatherKind = classify(self, slots, now)
    local window = { at = now, kind = kind, gatherKind = gatherKind, items = {}, order = {}, got = {},
        -- Carried to the settle, so a window settled while the next one opens still names its own
        -- corpse rather than whichever was opened last.
        sourceGUID = slots[1] and slots[1].sourceGUID }
    for _, slot in ipairs(slots) do
        if slot.itemID and not window.items[slot.itemID] then
            window.items[slot.itemID] = {
                sourceID = slot.sourceID, sourceGUID = slot.sourceGUID, sourceType = slot.sourceType,
                material = slot.classID == LootRules.MATERIAL_CLASS,
            }
            window.order[#window.order + 1] = slot.itemID
        end
    end
    self.window = window
    return earlier
end

-- "You receive loot: [item]" for itemID x quantity. Collected against the open (or just closed)
-- window; returns true when it was one of that window's items.
function LootRules:onReceived(itemID, quantity, now)
    local window = self.window
    if not window or not window.items[itemID] then return false end
    if now - window.at > LootRules.WINDOW + LootRules.GRACE and not window.closedAt then return false end
    window.got[itemID] = (window.got[itemID] or 0) + (quantity or 1)
    return true
end

function LootRules:onLootClosed(now)
    if self.window and not self.window.closedAt then self.window.closedAt = now end
end

-- Settles a closed window. Returns nil when there is nothing to settle yet, otherwise
--   { kind = "gather" | "corpse" | "other", sourceGUID = the window's source,
--     received = { [itemID] = count, ... },  -- every item the window held; 0 if left behind
--     gathered = { Gathered values, ... } }   -- gather windows only
-- In a gather window, the first material received from a node never seen before marks the node
-- (lootIndex 1), so a vein swung three times is still one vein. `force` settles without waiting
-- out the grace (a new window opened).
function LootRules:settle(now, force)
    local window = self.window
    if not window or not window.closedAt then return nil end
    if not force and now - window.closedAt < LootRules.GRACE then return nil end
    self.window = nil

    local result = { kind = window.kind, sourceGUID = window.sourceGUID, received = {}, gathered = {} }
    local marked = {}
    for _, itemID in ipairs(window.order) do
        local item, count = window.items[itemID], window.got[itemID] or 0
        result.received[itemID] = count
        if window.kind == "gather" and count > 0 and item.material and item.sourceGUID
            and item.sourceType == (window.gatherKind == LootRules.SKIN and "Creature" or "GameObject") then
            local first = not self.nodes[item.sourceGUID] and not marked[item.sourceGUID]
            if first then marked[item.sourceGUID] = true end
            result.gathered[#result.gathered + 1] = {
                kind = window.gatherKind, sourceID = item.sourceID, itemID = itemID, quantity = count,
                lootIndex = first and 1 or 2,
            }
        end
    end
    for guid in pairs(marked) do remember(self, guid) end
    return result
end

-- "You create: [item]" for itemID x quantity. Returns the Crafted fact's values, or nil.
function LootRules:onCreated(itemID, quantity, now)
    local spell = self.lastSpell
    if not spell or now - spell.at > LootRules.CRAFT_WINDOW or not itemID then return nil end
    return { spellID = spell.spellID, itemID = itemID, quantity = quantity or 1 }
end

if ns then ns.LootRules = LootRules end
return LootRules
