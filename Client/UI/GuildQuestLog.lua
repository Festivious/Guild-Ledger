-- The guild quest log and its tracker.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 2 ("A quest's life").
-- Guild quests are accepted at a mailbox and live here until they are turned in. The game's own
-- quest log cannot hold them (addons cannot write to it) and Questie's public API only reads, so
-- this is ours: a tracker on screen the way the game's quest tracker sits, and a log grouped under
-- zone headers the way the game's log groups its quests.
local _, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

-- Not ns.QuestLog: that name, and ns.questLog, belong to the capture's record of the game's
-- own quest log (Capture/QuestLog.lua).
local QuestLog = {}
ns.GuildQuestLog = QuestLog

local TRACKER_LINES = 12
local UPDATE_EVERY = 3

local tracker, window

local function zoneName(zone)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(zone)
    return info and info.name or ("zone " .. tostring(zone))
end

-- The tracker ---------------------------------------------------------------------------------

local function buildTracker()
    tracker = CreateFrame("Button", "GuildLedgerQuestTracker", UIParent)
    tracker:SetSize(220, 20)
    -- Where the game's quest tracker sits, under the minimap, a little to its left so the two
    -- can be read side by side.
    tracker:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -230, -210)
    tracker:SetFrameStrata("LOW")

    tracker.header = tracker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tracker.header:SetPoint("TOPLEFT")
    tracker.header:SetText("Guild Quests")

    tracker.lines = {}
    for i = 1, TRACKER_LINES do
        local line = tracker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", tracker, "TOPLEFT", (i % 2 == 0) and 10 or 0, -14 - (i - 1) * 12)
        line:SetWidth(220)
        line:SetJustifyH("LEFT")
        tracker.lines[i] = line
    end

    tracker:RegisterForClicks("LeftButtonUp")
    tracker:SetScript("OnClick", function() QuestLog.toggle() end)
    tracker:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Guild Quests", 1, 0.82, 0)
        GameTooltip:AddLine("Click to open your guild quest log.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    tracker:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local elapsed = UPDATE_EVERY
    tracker:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed < UPDATE_EVERY then return end
        elapsed = 0
        QuestLog.refreshTracker()
    end)
end

-- Two lines a quest: its title, then how far along it is. Hidden when the log is empty.
function QuestLog.refreshTracker()
    if not tracker then return end
    local ok, groups = pcall(ns.guildQuestLog)
    if not ok then groups = {} end
    local n = 0
    for _, group in ipairs(groups) do
        for _, row in ipairs(group.rows) do
            if n + 2 <= TRACKER_LINES then
                local done = row.progress and row.progress.done
                tracker.lines[n + 1]:SetText(row.entry.title)
                tracker.lines[n + 1]:SetTextColor(1, 0.82, 0)
                tracker.lines[n + 2]:SetText("- " .. ns.describeProgress(row))
                if done then tracker.lines[n + 2]:SetTextColor(0.45, 0.85, 0.45)
                else tracker.lines[n + 2]:SetTextColor(0.9, 0.9, 0.9) end
                n = n + 2
            end
        end
    end
    for i = n + 1, TRACKER_LINES do tracker.lines[i]:SetText("") end
    tracker:SetHeight(16 + n * 12)
    tracker:SetShown(n > 0)
    if window and window:IsShown() then QuestLog.refreshWindow() end
end

-- The log window ------------------------------------------------------------------------------

local selected

local function buildWindow()
    window = CreateFrame("Frame", "GuildLedgerQuestLogFrame", UIParent, "BackdropTemplate")
    window:SetSize(360, 400)
    window:SetPoint("CENTER", UIParent, "CENTER", -200, 40)
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetClampedToScreen(true)
    if window.SetBackdrop then
        window:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    end
    -- Escape closes it, like the game's quest log.
    table.insert(UISpecialFrames, "GuildLedgerQuestLogFrame")

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Guild Quest Log")

    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    -- The list: zone headers and quests, top half.
    local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -40)
    scroll:SetPoint("TOPRIGHT", -34, -40)
    scroll:SetHeight(190)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(300, 10)
    scroll:SetScrollChild(content)
    window.content, window.rows = content, {}

    -- The selected quest: its note and where it ends, bottom half.
    local detail = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detail:SetPoint("TOPLEFT", 18, -242)
    detail:SetPoint("TOPRIGHT", -18, -242)
    detail:SetJustifyH("LEFT")
    detail:SetJustifyV("TOP")
    detail:SetHeight(110)
    window.detail = detail

    local abandon = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    abandon:SetSize(100, 22)
    abandon:SetPoint("BOTTOMLEFT", 16, 14)
    abandon:SetText("Abandon")
    abandon:SetScript("OnClick", function()
        if not selected then return end
        local ok, why = ns.abandonHard(selected)
        if not ok then GBA.Print("|cffffcc00" .. tostring(why) .. "|r") end
        selected = nil
        QuestLog.refreshTracker()
        QuestLog.refreshWindow()
    end)
    window.abandon = abandon

    -- The analytics frame: this character's sessions, told as plays (UI/Analytics.lua).
    local analytics = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    analytics:SetSize(100, 22)
    analytics:SetPoint("BOTTOMRIGHT", -16, 14)
    analytics:SetText("Analytics")
    analytics:SetScript("OnClick", function()
        if ns.Analytics then ns.Analytics.toggle() end
    end)

    window:SetScript("OnShow", function() QuestLog.refreshWindow() end)
    window:Hide()
end

local function rowButton(index)
    local b = window.rows[index]
    if b then return b end
    b = CreateFrame("Button", nil, window.content)
    b:SetSize(300, 16)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("LEFT")
    b.text:SetJustifyH("LEFT")
    b.text:SetWidth(300)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:SetScript("OnClick", function(self)
        if self.questID then selected = self.questID; QuestLog.refreshWindow() end
    end)
    window.rows[index] = b
    return b
end

function QuestLog.refreshWindow()
    if not window then return end
    local ok, groups = pcall(ns.guildQuestLog)
    if not ok then groups = {} end

    local n, y, chosen = 0, 0, nil
    for _, group in ipairs(groups) do
        n = n + 1
        local header = rowButton(n)
        header:SetPoint("TOPLEFT", window.content, "TOPLEFT", 0, -y)
        header.questID = nil
        header.text:SetText(zoneName(group.zone))
        header.text:SetTextColor(0.75, 0.61, 0)
        header:Show()
        y = y + 16
        for _, row in ipairs(group.rows) do
            n = n + 1
            local b = rowButton(n)
            b:SetPoint("TOPLEFT", window.content, "TOPLEFT", 12, -y)
            b.questID = row.entry.id
            local done = row.progress and row.progress.done
            b.text:SetText(row.entry.title .. "  |cffbbbbbb" .. ns.describeProgress(row) .. "|r")
            if done then b.text:SetTextColor(0.45, 0.85, 0.45) else b.text:SetTextColor(1, 0.82, 0) end
            b:Show()
            y = y + 16
            if selected == row.entry.id then chosen = row end
        end
    end
    for i = n + 1, #window.rows do window.rows[i]:Hide() end
    window.content:SetHeight(math.max(10, y))

    if chosen then
        window.detail:SetText(chosen.entry.title .. "\n\n" .. (chosen.entry.note or "") ..
            "\n\n|cffffd100" .. ns.describeProgress(chosen) .. "|r\nTurned in at " .. ns.turnInPlace(chosen.entry) .. ".")
        window.abandon:Enable()
    else
        selected = nil
        window.detail:SetText(n == 0 and "No guild quests yet. Officers switch them on zone by zone;"
            .. " accept them at a mailbox." or "Select a quest.")
        window.abandon:Disable()
    end
end

function QuestLog.toggle()
    if not window then
        local ok, err = pcall(buildWindow)
        if not ok then
            if GBA.recordError then pcall(GBA.recordError, "guild quest log: " .. tostring(err), "") end
            return GBA.Print("|cffff4040the guild quest log could not open:|r " .. tostring(err))
        end
    end
    window:SetShown(not window:IsShown())
end

-- Built at login, when the log has been restored and there is a screen to draw on.
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function()
    boot:UnregisterEvent("PLAYER_ENTERING_WORLD")
    local ok, err = pcall(buildTracker)
    if not ok and GBA.recordError then pcall(GBA.recordError, "guild quest tracker: " .. tostring(err), "") end
    if ok then QuestLog.refreshTracker() end
end)

