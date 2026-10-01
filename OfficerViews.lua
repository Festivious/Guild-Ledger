-- The officer's views in the analytics frame: open claims, claims held for others, and the
-- decision log (docs/fix-plan.md, V1). Each is a side tab and a drawer beside the frame, so none
-- covers the map (DEC-17). Until these, each existed only as a dev command.
--
--   Claims     every undecided claim this officer may decide, newest first. Award fills in the
--              reward mail, so it works at a mailbox; Decline works anywhere.
--   Held       claims this officer holds for another poster, and whether each is on a disk.
--   Decisions  the signed log: who awarded, declined or requeued what, and whether the player
--              has heard.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Analytics = ns.Analytics
if not Analytics then return end

local Reward, Resolve = GBA.Reward, GBA.Resolve

local ROW_HEIGHT = 70
local REFRESH = 2

local function ago(t)
    if type(t) ~= "number" then return "" end
    local s = math.max(0, GBA.now() - t)
    if s < 3600 then return math.floor(s / 60) .. " min ago" end
    if s < 86400 then return math.floor(s / 3600) .. " h ago" end
    return math.floor(s / 86400) .. " d ago"
end

local function titleOf(rewardID, fallback)
    local offer = (ns.offerCatalog and ns.offerCatalog:get(rewardID))
        or (ns.rewardCatalog and ns.rewardCatalog:get(rewardID))
    return offer and offer.title or fallback or tostring(rewardID)
end

-- A drawer panel with a scrolling area; body(content, width) fills it on every refresh.
local function scrolling(area, body)
    local panel = CreateFrame("Frame", nil, area)
    panel:SetAllPoints(area)
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 2, -2)
    scroll:SetPoint("BOTTOMRIGHT", -24, 2)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    scroll:SetScrollChild(content)
    function panel.refresh()
        local width = math.max(100, (scroll:GetWidth() or 200) - 4)
        content:SetWidth(width)
        local ok, height = pcall(body, content, width)
        if not ok then
            if GBA.recordError then pcall(GBA.recordError, "officer view: " .. tostring(height), "") end
            height = 10
        end
        content:SetHeight(math.max(10, height or 10))
    end
    local elapsed = 0
    panel:SetScript("OnShow", function() elapsed = 0; panel.refresh() end)
    panel:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed >= REFRESH then elapsed = 0; panel.refresh() end
    end)
    panel:Hide()
    return panel
end

-- A plain text list: lines(), one entry per line, or an empty-state line.
local function textList(area, lines)
    local text
    return scrolling(area, function(content, width)
        if not text then
            text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("TOPLEFT", 2, -2)
            text:SetJustifyH("LEFT")
            text:SetSpacing(3)
        end
        text:SetWidth(width - 4)
        text:SetText(table.concat(lines(), "\n"))
        return (text:GetStringHeight() or 10) + 8
    end)
end

-- Claims ---------------------------------------------------------------------------------------

StaticPopupDialogs["GUILDLEDGER_DECLINE_CLAIM"] = {
    text = "Decline %s's claim on \"%s\"?\n\nReturn anything they mailed by hand, with your reasons.",
    button1 = "Decline",
    button2 = CANCEL or "Cancel",
    OnAccept = function(_, id)
        local ok, err = ns.declineClaim(id)
        GBA.Print(ok and "declined; the player is told when online" or ("|cffff4040" .. tostring(err) .. "|r"))
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Undecided claims this officer may decide, newest first.
local function openClaims()
    local out = {}
    for _, r in ipairs(ns.officerClaims and ns.officerClaims:open() or {}) do
        if ns.decidable and ns.decidable(r.rewardID) then out[#out + 1] = r end
    end
    return out
end

local function claimRow(content)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_HEIGHT)
    row.line = row:CreateTexture(nil, "BACKGROUND")
    row.line:SetColorTexture(1, 1, 1, 0.08)
    row.line:SetPoint("BOTTOMLEFT", 0, 0)
    row.line:SetPoint("BOTTOMRIGHT", 0, 0)
    row.line:SetHeight(1)
    row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.head:SetPoint("TOPLEFT", 2, -3)
    row.head:SetJustifyH("LEFT")
    row.body = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.body:SetPoint("TOPLEFT", row.head, "BOTTOMLEFT", 0, -2)
    row.body:SetJustifyH("LEFT")
    row.decline = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.decline:SetSize(64, 18)
    row.decline:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 4)
    row.decline:SetText("Decline")
    row.award = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.award:SetSize(64, 18)
    row.award:SetPoint("RIGHT", row.decline, "LEFT", -4, 0)
    row.award:SetText("Award")
    row.award:SetMotionScriptsWhileDisabled(true)
    row.award:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Award", 1, 1, 1)
        GameTooltip:AddLine(self:IsEnabled() and "Fills in the reward mail; the award counts when it is sent."
            or "At a mailbox: the award goes by mail.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row.award:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

Analytics.addLayer({
    key = "claims", label = "Claims", order = 20, drawerWidth = 330,
    icon = "Interface\\Icons\\INV_Letter_15",
    hint = "Open claims on the offers you decide.",
    build = function(_, area)
        local rows = {}
        local panel
        panel = scrolling(area, function(content, width)
            local list = openClaims()
            local names = Resolve.live(GBA.spokes)
            local atMailbox = GBA.Mailbox and GBA.Mailbox.isOpen()
            for i, r in ipairs(list) do
                local row = rows[i] or claimRow(content)
                rows[i] = row
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
                row:SetWidth(width)
                row.head:SetWidth(width - 4)
                row.body:SetWidth(width - 4)
                row.head:SetText(string.format("%s  -  %s", r.from, titleOf(r.rewardID, r.title)))
                local bits = {}
                local sending = Reward.describeEntries(r.sending, Resolve, names)
                bits[#bits + 1] = "sent: " .. (sending or "nothing")
                if r.transferID then
                    bits[#bits + 1] = "data: " .. (ns.Vault and ns.Vault.status(r.transferID) or "?")
                end
                -- A guild quest's evidence, recounted (hard-quest spec, Part 3).
                local offer = ns.decidable and ns.decidable(r.rewardID)
                local verified = ns.verifiedText and ns.verifiedText(r.verified or (ns.verifyEvidence and ns.verifyEvidence(r, offer)))
                if verified then bits[#bits + 1] = verified end
                if r.repeated then bits[#bits + 1] = "|cffffcc00already awarded before|r" end
                bits[#bits + 1] = ago(r.at) .. (r.saved and "" or ", not yet saved")
                row.body:SetText(table.concat(bits, "\n"))
                row.award:SetEnabled(atMailbox and true or false)
                row.award:SetScript("OnClick", function()
                    local ok, err = ns.AwardFlow and ns.AwardFlow.begin(r.id)
                    if not ok then GBA.Print("|cffff4040" .. tostring(err) .. "|r") end
                end)
                row.decline:SetScript("OnClick", function()
                    local dialog = StaticPopup_Show("GUILDLEDGER_DECLINE_CLAIM", r.from, titleOf(r.rewardID, r.title))
                    if dialog then dialog.data = r.id end
                    C_Timer.After(0.2, function() if panel:IsShown() then panel.refresh() end end)
                end)
                row:Show()
            end
            for i = #list + 1, #rows do rows[i]:Hide() end
            if #list == 0 then
                rows.empty = rows.empty or content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                rows.empty:SetPoint("TOPLEFT", 2, -4)
                rows.empty:SetText("No open claims on the offers you decide.")
                rows.empty:Show()
                return 20
            end
            if rows.empty then rows.empty:Hide() end
            return #list * ROW_HEIGHT
        end)
        return panel
    end,
})

-- Held -----------------------------------------------------------------------------------------

Analytics.addLayer({
    key = "held", label = "Held", order = 21, drawerWidth = 300,
    icon = "Interface\\Icons\\INV_Box_01",
    hint = "Claims you hold for another poster until they have them on disk.",
    build = function(_, area)
        return textList(area, function()
            local held = ns.officerClaims and ns.officerClaims:heldFor() or {}
            if #held == 0 then return { "|cff808080Nothing held for other officers.|r" } end
            local lines = {}
            for _, h in ipairs(held) do
                lines[#lines + 1] = string.format("|cffffd100%s|r  -  %s", h.from, titleOf(h.claim.rewardID))
                lines[#lines + 1] = string.format("   for %s, held %s, %s", h.issuer, ago(h.heldAt),
                    h.saved and "saved" or "|cffffcc00not yet saved|r")
            end
            return lines
        end)
    end,
})

-- Decisions ------------------------------------------------------------------------------------

local WHAT = {
    [Reward.state.settled] = "awarded",
    [Reward.state.declined] = "declined",
}

Analytics.addLayer({
    key = "decisions", label = "Decisions", order = 22, drawerWidth = 320,
    icon = "Interface\\Icons\\INV_Scroll_03",
    hint = "The signed log of who decided what, and whether the player has heard.",
    build = function(_, area)
        return textList(area, function()
            local list = ns.officerClaims and ns.officerClaims:decisions() or {}
            if #list == 0 then return { "|cff808080No signed decisions yet.|r" } end
            local lines = {}
            for _, n in ipairs(list) do
                local what = n.kind == "requeue" and "requeued" or (WHAT[n.state] or "decided")
                local heard = ns.officerClaims.done[n.key] and "heard" or "|cffffcc00not yet heard|r"
                lines[#lines + 1] = string.format("|cffffd100%s|r %s %s", tostring(n.by), what, tostring(n.to))
                lines[#lines + 1] = string.format("   %s, %s, %s", titleOf(n.rewardID),
                    date("%d %b %H:%M", n.signedAt or 0), heard)
            end
            return lines
        end)
    end,
})
