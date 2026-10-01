-- Vendor inventories. No addon records vendor stock, so this is scanned directly.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema, GUID = GBA.Schema, ns.GUID
local episodes, buffer = ns.episodes, ns.buffer

local function scanMerchant()
    local npcID = GUID.npcID(UnitGUID("npc") or "")
    if not npcID then return end

    local slots = GetMerchantNumItems and GetMerchantNumItems() or 0
    local episode, now = episodes:current(), time()

    for slot = 1, slots do
        local link = GetMerchantItemLink and GetMerchantItemLink(slot)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if itemID then
            local _, _, price, quantity, available = GetMerchantItemInfo(slot)
            local values = Schema.toArray(Schema.factType.vendor_inventory, {
                npcID = npcID,
                itemID = itemID,
                price = price,
                -- -1 means unlimited stock in the Blizzard API; keep it as reported.
                stock = available,
            })
            buffer:add(Schema.factType.vendor_inventory, values, episode, now)
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:SetScript("OnEvent", scanMerchant)

