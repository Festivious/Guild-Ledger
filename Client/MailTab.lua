-- The Rewards tab: one registration, and the panel it opens.
--
-- Everything about the tab STRIP - building the button, picking an index, the -15 overlap,
-- SetNumTabs, the MailFrameTab_OnClick hook, hiding whatever was on screen before - now
-- lives in Core's MailTabs. It moved because it could not stay: an officer running this
-- addon and GuildLedger_Guild wants four tabs on the mailbox, and the version of this file
-- that computed its own index as (numTabs or 2) + 1 was right exactly once. Worse, its tab
-- called selectOurs directly instead of going through Blizzard's handler, so a second
-- addon's tab had no way to learn it should stand down.
--
-- What is left here is what was always this addon's business: which panel, and what it is
-- called.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

if not GBA.MailTabs then
    GBA.Print("|cffffcc00this LibGuildLedger is too old for the Rewards tab|r")
    return
end

ns.rewardsTab = GBA.MailTabs.register({
    key = "rewards",
    -- The list is the inbox, so it wears the inbox: parchment, inset and all.
    wears = "inbox",
    label = "Rewards",

    build = function(host)
        return ns.RewardsPanel and ns.RewardsPanel.buildPanel(host)
    end,

    -- Opened, not merely shown: an offer may have arrived, or a level, while the tab sat
    -- hidden behind the inbox.
    onShow = function()
        if ns.RewardsPanel then ns.RewardsPanel.refresh() end
    end,
})

-- The count is pushed in by Rewards.lua whenever the catalog changes, which can be long
-- before the player has opened a mailbox. MailTabs holds it until there is a tab to put
-- it on.
local frame = CreateFrame("Frame")
frame:RegisterEvent("MAIL_SHOW")
frame:SetScript("OnEvent", function()
    local ok, reason = GBA.MailTabs.attach()
    if not ok and reason and not ns.mailTabWarned then
        ns.mailTabWarned = true
        GBA.Print("|cffffcc00" .. reason .. "; use the panel beside the mailbox instead|r")
    end
    if ok and ns.rewardCatalog then
        ns.rewardsTab.setCount(ns.rewardCatalog:count())
    end
end)
