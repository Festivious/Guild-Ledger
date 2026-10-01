-- What the player is carrying, and what they are holding.
--
-- Two jobs, both about stacks, both needing the client:
--
--   snapshot()     the bags as a flat list, which Stacks plans attachments against
--   cursorStack()  how many are on the cursor right now
--
-- The second one exists because the client will not answer it. GetCursorInfo hands back
-- "item" and an itemID and stops there, so an officer dragging a stack of twenty Copper Bar
-- into an offer slot and an officer dragging one bar look identical at the moment of the
-- drop. Every slot in this addon recorded a quantity of one for that reason.
--
-- The count is knowable a moment EARLIER, though: whatever put the item on the cursor knew
-- how many it was picking up. So we watch the picking-up rather than the holding. The
-- item never leaves its bag slot while it is on the cursor - which is why Escape puts it
-- back - so the hook can still read the slot it came from.
--
-- The remembered count is only ever trusted while the cursor still holds the same item, and
-- a caller that gets nil back is expected to carry on with a sensible default rather than
-- refuse the drop. This is a nicety that makes a drag mean what it looked like it meant; it
-- is not load-bearing, and a client that hooks none of these still works.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Bags = {}

local BAG_SLOTS = _G.NUM_BAG_SLOTS or 4

local function numSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag) or 0
    end
    return (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
end

-- itemID and stack count for one bag slot, across both spellings of the container API.
local function slotItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if type(info) ~= "table" then return nil end
        return info.itemID, info.stackCount or 1
    end
    if GetContainerItemInfo then
        local _, count, _, _, _, _, _, _, _, itemID = GetContainerItemInfo(bag, slot)
        return itemID, count or 1
    end
    return nil
end

Bags.slotItem = slotItem

-- The bags as one list, in bag order. Backpack first, which is where a stack the player
-- just picked up usually is.
function Bags.snapshot()
    local out = {}
    for bag = 0, BAG_SLOTS do
        for slot = 1, numSlots(bag) do
            local itemID, count = slotItem(bag, slot)
            if itemID then
                out[#out + 1] = { bag = bag, slot = slot, itemID = itemID, count = count or 1 }
            end
        end
    end
    return out
end

-- How many of an item the bags hold. GetItemCount would answer this too, but it counts the
-- bank and the reagent bag on clients that have them, and an attachment cannot come from
-- either.
function Bags.count(itemID)
    local total = 0
    for _, stack in ipairs(Bags.snapshot()) do
        if stack.itemID == itemID then total = total + stack.count end
    end
    return total
end

-- How many of an item fit in one slot. Twenty for Linen Cloth, one for a sword, two
-- hundred for arrows - and the ceiling on what a single item slot, ours or the mailbox's,
-- can be asked for.
--
-- nil when the client has not cached the item yet, which is a MISS rather than a limit of
-- one: clamping an uncached item to one would quietly rewrite a quantity the officer set
-- correctly. ItemCache is how a caller that cares waits for the real answer.
function Bags.maxStack(itemID)
    if type(GetItemInfo) ~= "function" or not itemID then return nil end
    local stack = select(8, GetItemInfo(itemID))
    if type(stack) == "number" and stack > 0 then return stack end
    return nil
end

-- The cursor -----------------------------------------------------------------------

-- { itemID = , count = } for the last pickup we saw, or nil.
local held

local function remember(count)
    if type(GetCursorInfo) ~= "function" then return end
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or not itemID or not count or count < 1 then
        held = nil
        return
    end
    held = { itemID = itemID, count = count }
end

-- How many the cursor is holding, or nil if this client never told us.
--
-- Guarded by the itemID: a count remembered for one item is never handed back for another,
-- so the worst a missed hook can do is fall through to the caller's default.
function Bags.cursorStack()
    if type(GetCursorInfo) ~= "function" then return nil end
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or not itemID then return nil end
    if held and held.itemID == itemID then return held.count end
    return nil
end

-- Hooks are post-call: by the time these run the item is on the cursor and the bag slot it
-- came from still reads as full, because a held item has not left its slot yet.
local function watch()
    if type(hooksecurefunc) ~= "function" then return end

    local function watchContainer(owner, name)
        local target = owner or _G
        if type(target[name]) ~= "function" then return end
        if owner then
            hooksecurefunc(owner, name, function(bag, slot)
                local _, count = slotItem(bag, slot)
                remember(count or 1)
            end)
        else
            hooksecurefunc(name, function(bag, slot)
                local _, count = slotItem(bag, slot)
                remember(count or 1)
            end)
        end
    end

    local function watchSplit(owner, name)
        local target = owner or _G
        if type(target[name]) ~= "function" then return end
        if owner then
            hooksecurefunc(owner, name, function(_, _, amount) remember(amount) end)
        else
            hooksecurefunc(name, function(_, _, amount) remember(amount) end)
        end
    end

    -- Both spellings, where both exist. A client where the global is a wrapper around the
    -- namespaced one fires both hooks with the same slot and remembers the same number
    -- twice, which costs nothing; a client with only one of them is why we look for each.
    watchContainer(nil, "PickupContainerItem")
    -- Shift-dragging a stack out of a bag is how the game already says "some of these",
    -- and it lands here. An officer who wants an offer to ask for five of a stack of forty
    -- splits five off and drops them, exactly as they would into a trade window.
    watchSplit(nil, "SplitContainerItem")
    if type(C_Container) == "table" then
        watchContainer(C_Container, "PickupContainerItem")
        watchSplit(C_Container, "SplitContainerItem")
    end

    if type(PickupInventoryItem) == "function" then
        hooksecurefunc("PickupInventoryItem", function(slot)
            local count = GetInventoryItemCount and GetInventoryItemCount("player", slot)
            remember(count and count > 0 and count or 1)
        end)
    end

    if type(PickupMerchantItem) == "function" then
        hooksecurefunc("PickupMerchantItem", function(index)
            local quantity = GetMerchantItemInfo and select(4, GetMerchantItemInfo(index))
            remember(quantity or 1)
        end)
    end

    if type(ClearCursor) == "function" then
        hooksecurefunc("ClearCursor", function() held = nil end)
    end
end

watch()

if ns then ns.Bags = Bags end
return Bags
