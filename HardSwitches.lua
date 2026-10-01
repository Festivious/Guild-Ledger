-- Officers switching hard-list quests on and off.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 2. A tick is an
-- offer: switching a quest on publishes an ordinary signed offer built from the catalog entry,
-- carrying its hardID, so everything offers already do - signing, relay by any officer, the
-- handshake that catches up whoever was offline, Remove - carries it unchanged. Nothing is on
-- until an officer ticks it, because the guild pays.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local HardQuest, HardList, Reward = GBA.HardQuest, GBA.HardList, GBA.Reward

-- A switch is renewed this long before it would expire, so a ticked quest never lapses while
-- its officer logs in now and then.
local RENEW_BEFORE = 5 * 86400

local byID = {}
for _, entry in ipairs(HardList or {}) do byID[entry.id] = entry end

-- The live switch for a quest, whoever posted it: this officer's own, or another officer's that
-- reached this client. Returns the offer, or nil.
function ns.hardSwitch(hardID)
    for _, catalog in ipairs({ ns.offerCatalog, ns.rewardCatalog }) do
        if catalog then
            for _, reward in ipairs(catalog:list()) do
                if reward.hardID == hardID and not Reward.hasExpired(reward, GBA.now()) then return reward end
            end
        end
    end
    return nil
end

-- Switches a quest on or off. Returns true, or nil and why.
function ns.switchHard(hardID, on)
    if not GBA.mayAct("offer") then return nil, "you may not publish offers" end
    local entry = byID[hardID]
    if not entry then return nil, "no such quest in this version's list" end

    local held = ns.hardSwitch(hardID)
    if on then
        if held then return true end   -- already on, by this officer or another
        local reward, why = ns.publishReward(HardQuest.toOfferFields(entry))
        if not reward then return nil, why end
        return true
    end

    if not held then return true end
    if not Reward.issuerMatches(held.issuer, UnitName("player")) then
        return nil, "switched on by " .. tostring(held.issuer) .. "; only they can switch it off"
    end
    local reward, why = ns.retractReward(held.id)
    if not reward then return nil, why end
    return true
end

-- Every quest in one zone, on or off together. Returns how many changed and the first problem.
function ns.switchHardZone(zone, on)
    local changed, problem = 0, nil
    for _, entry in ipairs(HardList or {}) do
        if entry.zone == zone and (ns.hardSwitch(entry.id) ~= nil) ~= on then
            local ok, why = ns.switchHard(entry.id, on)
            if ok then changed = changed + 1 elseif not problem then problem = why end
        end
    end
    return changed, problem
end

-- This officer's own switches that are close to expiring are revised, which restarts the expiry.
-- The revision is built from the catalog again, so a changed title, note or pay in a newer
-- addon version reaches members at the same time.
local function renew()
    if not ns.offerCatalog or not GBA.mayAct("offer") then return end
    local now = GBA.now()
    for _, reward in ipairs(ns.offerCatalog:list()) do
        local entry = reward.hardID and byID[reward.hardID]
        if entry and type(reward.expiresAt) == "number" and reward.expiresAt - now < RENEW_BEFORE
            and Reward.issuerMatches(reward.issuer, UnitName("player")) then
            ns.reviseReward(reward.id, HardQuest.toOfferFields(entry))
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
    frame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    -- After the officer key and the catalogs have loaded and the login rush has passed.
    C_Timer.After(30, renew)
end)

