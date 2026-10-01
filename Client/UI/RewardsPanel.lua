-- The Rewards tab itself: one panel, two views, one swap between them.
--
-- The list and the detail are siblings that take turns, not windows. Clicking an offer
-- hides one and shows the other in the same space, and Back does the reverse - a frame
-- swap, which is what the quest log does between its list and its detail and what keeps
-- this feeling like a part of the mailbox rather than something layered over it.
--
-- One panel, two hosts, and the panel MOVES between them rather than being built twice.
-- Embedded it is the Rewards tab inside MailFrame; standalone it is a window beside the
-- mailbox, which is what a client that cannot take a third tab falls back to.
--
-- It is built as its own frame and reparented, because the first version decided at
-- construction time which host it belonged to and got it wrong: ClaimFlow registers
-- MAIL_SHOW before MailTab does, so the window was built before the tab existed and the
-- tab was then handed that floating window as its panel. Nothing here may depend on which
-- handler runs first. A panel that can move is a panel that cannot be built against the
-- wrong host.
--
-- The panel now covers the WHOLE host rather than an inset of it, and that is a deliberate
-- reversal. It used to sit at 8,-26 with margins cut from MailFrameInset, and the margins
-- were the problem: two /gba wireframe runs of the same tab measured the inset at 4,-58
-- 328x362 and at 4,-80 328x318. Blizzard reshapes it depending on which of its own frames
-- was last shown, so every number cut from it is right until the player visits Send Mail.
--
-- Nothing inside the panel is positioned against the panel any more. The list anchors to
-- MailItem1..7, the claim view to the send-mail furniture, and both to Blizzard's frames
-- directly - so what the panel needs to be is simply the same rectangle as the host, and
-- then it is out of the way.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Panel = {}
ns.RewardsPanel = Panel

-- Only reached if the host cannot say how big it is, which should not happen once the
-- mailbox has drawn itself. MailFrame measures 338 x 424 on this client - not the 384 x 512
-- its XML declares - and that is what the standalone window is cut to as well, so a client
-- that falls back to a window gets the same layout rather than a squeezed one.
local FALLBACK_W, FALLBACK_H = 338, 424

local panel, window, list, detail

-- Where the mailbox says what it is showing.
--
-- Ours, not Blizzard's, and that is the whole fix for the doubled title. The old code wrote
-- MailFrameTitleText and never put it back, so "Level 10 Reward" stayed on the frame while
-- Blizzard drew "Inbox" over it from InboxTitleText - two strings, both showing, which is
-- what the screenshots caught. /gba uiprobe confirmed the three are separate regions:
-- MailFrameTitleText on MailFrame, InboxTitleText on InboxFrame, SendMailTitleText on
-- SendMailFrame.
--
-- A string of our own, centred on whichever of Blizzard's is there, cannot collide with any
-- of them: MailTabs covers theirs with alpha while our tab is up, and ours hides with the
-- panel when it is not. Nothing is written to and nothing needs restoring.
--
-- Anchoring to a covered region is fine. Alpha changes what is drawn, not where it is, so
-- the title lands on Blizzard's own centre whether or not that string is visible.
local TITLE_SOURCES = { "InboxTitleText", "SendMailTitleText", "MailFrameTitleText" }

local function addTitle()
    if panel.title then return end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local source = ns.Skin.firstOf(unpack(TITLE_SOURCES))

    if source then
        -- Centred on Blizzard's own, so it does not matter what that one is anchored to.
        -- InboxFrame measures 384 wide inside a 338-wide MailFrame, so a title centred on
        -- the panel would sit 23 units off the one it is replacing.
        title:SetPoint("CENTER", source, "CENTER", 0, 0)
        if source.GetFontObject and source:GetFontObject() then
            title:SetFontObject(source:GetFontObject())
        end
    else
        title:SetPoint("TOP", panel, "TOP", 0, -18)
    end

    panel.title = title
end

local function create()
    if panel then return panel end
    ns.Skin.load()

    panel = CreateFrame("Frame", "GuildLedgerPanel", UIParent)
    panel:SetSize(FALLBACK_W, FALLBACK_H)

    -- No paper here. The two views want different sheets in different places - the list
    -- fills the inbox's own background region, the claim view papers only its letter body
    -- and leaves the rest on the frame's own chrome, exactly as Send Mail does - so each
    -- lays its own.
    panel:Hide()
    return panel
end

-- What the panel should be inside this host. Arithmetic, so it is right immediately:
-- a frame sized by two corners does not report that size to GetWidth until a layout pass
-- has run, and the views are built from what it reports.
local function sizeFor(host)
    local hostWidth = host and host.GetWidth and host:GetWidth() or 0
    local hostHeight = host and host.GetHeight and host:GetHeight() or 0

    if hostWidth < 100 or hostHeight < 100 then return FALLBACK_W, FALLBACK_H end
    return math.floor(hostWidth), math.floor(hostHeight)
end

-- The views, once, at the size the panel was given. They anchor to all four of its
-- corners, so a panel that is later re-anchored carries them with it.
local function addViews()
    if list then return end

    local width = math.floor(panel:GetWidth() or 0)
    local height = math.floor(panel:GetHeight() or 0)
    if width < 100 then width = FALLBACK_W end
    if height < 100 then height = FALLBACK_H end

    list = ns.RewardList.build(panel, width, height)
    list:SetAllPoints(panel)

    -- Refresh: asks the online officers for the current offers, the same request made at
    -- login. On the list, so it goes when an offer is opened. Placed top right for now.
    local refresh = CreateFrame("Button", nil, list, "UIPanelButtonTemplate")
    refresh:SetText("Refresh")
    refresh:SetSize(74, 20)
    refresh:SetPoint("TOPRIGHT", list, "TOPRIGHT", -12, -40)
    refresh:SetScript("OnClick", function()
        if ns.syncOffers then ns.syncOffers(false) end
    end)
    list.refreshButton = refresh

    -- Two lists share the rows: the officers' offers, and the guild quests switched on for the
    -- zone the player is standing in. The button names the list it goes to, not the one shown.
    -- Spec: 2026-09-25-hard-quest-list-design.md, Part 2.
    local modeButton = CreateFrame("Button", nil, list, "UIPanelButtonTemplate")
    modeButton:SetSize(96, 20)
    modeButton:SetPoint("RIGHT", refresh, "LEFT", -4, 0)
    local function label()
        modeButton:SetText(list.mode == "zone" and "Guild offers" or "Zone quests")
    end
    modeButton:SetScript("OnClick", function()
        if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION or 88) end
        list.mode = list.mode == "zone" and "offers" or "zone"
        list.page = 1
        label()
        list:refresh()
    end)
    label()
    list.modeButton = modeButton

    detail = ns.RewardDetail.build(panel, width, height)
    detail:SetAllPoints(panel)
    detail:Hide()
end

-- Hosts -----------------------------------------------------------------------

-- Takes the panel into the mailbox's own frame. Called by MailTab once its tab exists.
function Panel.buildPanel(host)
    create()

    -- A window opened before the tab attached is the wrong home for it, and there is only
    -- one panel, so it comes back.
    if window then window:Hide() end

    panel:SetParent(host)
    panel:ClearAllPoints()
    -- The host's own rectangle, corner to corner. Everything inside anchors to Blizzard's
    -- frames rather than to this, so the panel is a container and nothing more.
    panel:SetSize(sizeFor(host))
    panel:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    panel.embedded = true

    addTitle()
    addViews()
    Panel.showList()
    panel:Hide()
    return panel
end

-- The standalone window, for a client whose mail frame would not take a third tab.
local function buildWindow()
    if window then return window end

    window = CreateFrame("Frame", "GuildLedgerWindow", UIParent, "DialogBoxFrame")
    window:SetSize(FALLBACK_W + 34, FALLBACK_H + 62)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:Hide()

    return window
end

function Panel.openWindow()
    create()
    buildWindow()

    panel:SetParent(window)
    panel:ClearAllPoints()
    panel:SetSize(FALLBACK_W, FALLBACK_H)
    panel:SetPoint("TOPLEFT", window, "TOPLEFT", 17, -17)
    -- Read by Skin.anchorTo: standing alone, our parts cannot be anchored onto Blizzard's
    -- frames, because those are over on the mail window. They are measured against
    -- MailFrame once and the offsets laid onto the panel instead.
    panel.embedded = false

    -- Standing alone there is no mail frame behind it, so the panel does need a sheet.
    if not panel.paper then
        panel.paper = ns.Skin.sheet(panel, "inbox", -1)
        panel.paper:SetAllPoints(panel)
    end

    window:ClearAllPoints()
    if _G.MailFrame and _G.MailFrame:IsShown() then
        -- Beside the mailbox rather than over it, so both are usable at once.
        window:SetPoint("TOPLEFT", _G.MailFrame, "TOPRIGHT", 8, 0)
    else
        window:SetPoint("CENTER")
    end

    window:Show()
    addTitle()
    addViews()
    panel:Show()
    Panel.showList()
end

function Panel.closeWindow()
    if window then window:Hide() end
end

-- Views -------------------------------------------------------------------------

-- Blizzard writes Inbox or Send Mail on its tabs; ours writes Rewards, and then the offer's
-- name once one is open. That is also why the claim view has no title line of its own:
-- Send Mail has not got one either.
function Panel.setTitle(text)
    if panel and panel.title then panel.title:SetText(text or "") end
end

function Panel.showList()
    if not list then return end
    detail:Hide()
    list:Show()
    list:refresh()
    Panel.setTitle("Rewards")

    -- Back onto the inbox. The list IS the inbox, and the frame underneath it should be too.
    if ns.rewardsTab then ns.rewardsTab.wear("inbox") end
end

function Panel.showDetail(reward)
    if not detail then return end
    ns.ClaimFlow.select(reward)
    list:Hide()
    detail:Show()

    -- Onto Send Mail FIRST, and the order is load-bearing now. Claiming IS sending mail, so
    -- the page this letter is read on is the real stationery rather than a copy of it -
    -- which is the same swap the tab strip makes for the officer's composer.
    --
    -- It used to be the last line of this function, which was harmless while the detail
    -- view only measured Blizzard's frames. It stopped being harmless when the view began
    -- borrowing Blizzard's scroll bar: wear() hands every borrowed thing back on its way
    -- through uncoverAll, so a view that took the bar and then asked to wear the frame gave
    -- the bar away in the same breath.
    if ns.rewardsTab then ns.rewardsTab.wear("sendmail") end

    ns.RewardDetail.show(detail, reward)
    Panel.setTitle(reward.title)
end

-- Redraws whichever view is up. Called when offers arrive, when a claim finishes, and
-- when the tab is opened.
function Panel.refresh()
    if not panel then return end
    if detail and detail:IsShown() then
        ns.RewardDetail.refresh()
    elseif list then
        list:refresh()
    end
end

function Panel.built()
    return panel ~= nil
end

function Panel.frame()
    return panel
end
