-- Identifiers to names, at READ time. No WoW API use of its own.
--
-- This is the other half of the hub-and-spoke bargain. The corpus stores npcID 38 and
-- never "Kobold Worker", because a name is locale-bound and twenty years of MobInfo2 data
-- proves what happens when you key a database by one. Questie, the item cache and the
-- client already know the names, in the reader's own language, so we look them up here
-- and throw them away again.
--
-- Providers are injected rather than reached for directly, so every degradation path is
-- testable without the game running. A missing provider is not an error: it produces a
-- thinner label. "npc 38" is a worse report than "Kobold Worker" and a far better one
-- than a broken addon or a guessed name.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Schema = ns and ns.Schema or require("Schema")

local Resolve = {}

local function usable(value)
    return type(value) == "string" and value ~= ""
end

local function lookup(provider, id, prefix)
    if id == nil then return "unknown" end
    if type(provider) == "function" then
        local ok, name = pcall(provider, id)
        if ok and usable(name) then return name end
    end
    return prefix .. " " .. tostring(id)
end

function Resolve.npc(providers, npcID)
    return lookup(providers and providers.npc, npcID, "npc")
end

function Resolve.item(providers, itemID)
    return lookup(providers and providers.item, itemID, "item")
end

function Resolve.spell(providers, spellID)
    return lookup(providers and providers.spell, spellID, "spell")
end

function Resolve.quest(providers, questID)
    return lookup(providers and providers.quest, questID, "quest")
end

-- Instance ids are stored negated to keep them out of the uiMapID namespace, so a map has
-- to be unpacked before anyone tries to name it.
function Resolve.map(providers, mapID)
    if mapID == nil then return "unknown" end
    local raw, isInstance = Schema.readMapID(mapID)
    return lookup(providers and providers.map, raw, isInstance and "instance" or "map")
end

-- An item as the game itself would draw it: the coloured, hoverable link, with the icon
-- and tooltip the client already knows. This is the payoff for storing an itemID rather
-- than a name — a German player reads "Leinenstoff" without anybody translating anything.
function Resolve.itemLink(providers, itemID, quantity)
    if itemID == nil then return "unknown" end

    local link
    if providers and type(providers.itemLink) == "function" then
        local ok, value = pcall(providers.itemLink, itemID)
        if ok and usable(value) then link = value end
    end

    -- GetItemInfo answers from the local cache and returns nothing for an item this client
    -- has not seen. That is a miss, not a failure: the label falls back to the id and
    -- resolves itself once the item is cached.
    link = link or ("item " .. tostring(itemID))

    if type(quantity) == "number" and quantity > 1 then
        link = link .. " x" .. quantity
    end

    -- The icon, inline, where the client can draw one. A hand-in list is read at a glance
    -- and against the player's own bags, and a bag is a wall of pictures - so a line that
    -- carries the same picture is matched instantly where a line of words has to be read.
    -- A texture escape works anywhere a fontstring does, chat included.
    if providers and type(providers.itemIcon) == "function" then
        local ok, icon = pcall(providers.itemIcon, itemID)
        if ok and (usable(icon) or type(icon) == "number") then
            return "|T" .. tostring(icon) .. ":14:14:0:0|t " .. link
        end
    end
    return link
end

-- Copper, the unit the game counts in, rendered the way a player reads it.
function Resolve.money(copper)
    if type(copper) ~= "number" or copper < 0 then return "nothing" end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local rest = copper % 100

    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if rest > 0 or #parts == 0 then parts[#parts + 1] = rest .. "c" end
    return table.concat(parts, " ")
end

-- Live providers, wired to whatever happens to be installed. Every one of these is
-- allowed to be absent.
function Resolve.live(spokes)
    return {
        npc = function(npcID)
            local npc = spokes and spokes:call("Questie", "getNPC", npcID)
            return type(npc) == "table" and npc.name or nil
        end,

        item = function(itemID)
            -- GetItemInfo answers from the local cache and returns nil for an item the
            -- client has not seen this session. That is a miss, not a failure: the label
            -- falls back to the id and resolves itself once the item is cached.
            if type(GetItemInfo) ~= "function" then return nil end
            return (GetItemInfo(itemID))
        end,

        -- The second return is the link: coloured by quality, hoverable, clickable.
        itemLink = function(itemID)
            if type(GetItemInfo) ~= "function" then return nil end
            return (select(2, GetItemInfo(itemID)))
        end,

        -- The tenth is the icon. Absent for an item this client has not cached, which is
        -- the same miss as the name: the line draws without a picture and gains one once
        -- ItemCache has been round.
        itemIcon = function(itemID)
            if type(GetItemInfo) ~= "function" then return nil end
            return (select(10, GetItemInfo(itemID)))
        end,

        spell = function(spellID)
            if type(GetSpellInfo) ~= "function" then return nil end
            return (GetSpellInfo(spellID))
        end,

        quest = function(questID)
            local db = spokes and spokes:call("Questie", "getQuest", questID)
            return type(db) == "table" and db.name or nil
        end,

        map = function(uiMapID)
            if not (C_Map and C_Map.GetMapInfo) then return nil end
            local info = C_Map.GetMapInfo(uiMapID)
            return type(info) == "table" and info.name or nil
        end,
    }
end

if ns then ns.Resolve = Resolve end
return Resolve
