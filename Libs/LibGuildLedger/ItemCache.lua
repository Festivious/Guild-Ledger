-- Asking the server for items this client has never seen.
--
-- The one place the hub-and-spoke bargain has a cost. Storing an itemID rather than a name
-- is right - a name is locale-bound and unmergeable - but it means the READER has to be
-- able to turn the id back into something. For npcs and quests that is free, because
-- Questie ships a whole database and it is always there. For items it is not: GetItemInfo
-- answers only from the local cache, and returns nothing for an item this character has
-- never laid eyes on.
--
-- Which is exactly what happened the first time a reward crossed the wire. The officer who
-- dragged Copper Bar into the slot saw "Copper Bar", because it was in his bags. The alt
-- receiving the offer saw "item 2840", because it never had been. The id was correct and
-- the display was useless.
--
-- The fix is that the client will fetch an item it does not know, asynchronously, if asked.
-- So: ask, and redraw when the answer arrives.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local ItemCache = {}

-- itemID -> list of callbacks waiting on it
local waiting = {}
local listener

local function isKnown(itemID)
    if type(GetItemInfo) ~= "function" then return false end
    return (GetItemInfo(itemID)) ~= nil
end

ItemCache.isKnown = isKnown

local function fulfil(itemID)
    local callbacks = waiting[itemID]
    if not callbacks then return end
    waiting[itemID] = nil
    for _, callback in ipairs(callbacks) do
        pcall(callback, itemID)
    end
end

-- GET_ITEM_INFO_RECEIVED is the fallback path, for a client without the Item mixin. It
-- fires for every item anything asks about, including other addons', so it matches against
-- what we are actually waiting on rather than redrawing on all of them.
local function ensureListener()
    if listener then return end
    listener = CreateFrame("Frame")
    listener:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    listener:SetScript("OnEvent", function(_, _, itemID)
        if itemID then fulfil(itemID) end
    end)
end

-- Asks for one item. The callback runs immediately if the client already knows it, and
-- otherwise once the server answers. An item that never resolves simply never calls back,
-- which leaves the id on screen rather than blocking anything.
function ItemCache.request(itemID, callback)
    if type(itemID) ~= "number" then return false end

    if isKnown(itemID) then
        if callback then pcall(callback, itemID) end
        return true
    end

    if callback then
        waiting[itemID] = waiting[itemID] or {}
        table.insert(waiting[itemID], callback)
    end
    ensureListener()

    -- The mixin is the direct way to ask and is present on Classic; Auctionator uses it
    -- here. Where it is missing, touching GetItemInfo is itself enough to start the fetch,
    -- and the event above catches the reply.
    if _G.Item and _G.Item.CreateFromItemID then
        local ok, item = pcall(_G.Item.CreateFromItemID, _G.Item, itemID)
        if ok and item and item.ContinueOnItemLoad then
            local started = pcall(item.ContinueOnItemLoad, item, function()
                fulfil(itemID)
            end)
            if started then return false end
        end
    end

    if type(GetItemInfo) == "function" then pcall(GetItemInfo, itemID) end
    return false
end

-- Asks for several at once and calls back ONCE when the last of them lands.
--
-- One callback rather than one per item because the caller is almost always redrawing a
-- list: redrawing it six times as six items trickle in costs six redraws to reach the same
-- picture.
function ItemCache.warm(itemIDs, callback)
    local pending, done = 0, false

    local function finished()
        pending = pending - 1
        if pending <= 0 and not done then
            done = true
            if callback then pcall(callback) end
        end
    end

    local unknown = {}
    for _, itemID in ipairs(itemIDs or {}) do
        if type(itemID) == "number" and not isKnown(itemID) then
            unknown[#unknown + 1] = itemID
        end
    end

    if #unknown == 0 then return 0 end

    pending = #unknown
    for _, itemID in ipairs(unknown) do
        ItemCache.request(itemID, finished)
    end
    return #unknown
end

-- Every itemID inside a list of reward entries, so a caller can warm a whole reward
-- without knowing the entry shape.
function ItemCache.idsIn(entries)
    local out = {}
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" and type(entry.itemID) == "number" then
            out[#out + 1] = entry.itemID
        end
    end
    return out
end

function ItemCache.pendingCount()
    local n = 0
    for _ in pairs(waiting) do n = n + 1 end
    return n
end

if ns then ns.ItemCache = ItemCache end
return ItemCache
