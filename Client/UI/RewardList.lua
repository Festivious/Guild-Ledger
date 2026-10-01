-- The Rewards tab, list view: every offer this character holds, as a stub you can read.
--
-- This IS the inbox, not a thing that resembles it. Each row is built from Blizzard's own
-- MailItemTemplate and anchored onto the MailItem it stands in for, so an offer occupies
-- the exact rectangle a letter would occupy in the same frame, wearing the same divider
-- rule and the same icon frame, with its text on the same grid.
--
-- What changed, and why it had to: the previous version measured MailItem1 at runtime and
-- copied its numbers into SetPoint calls of its own, then drew the row itself. That is
-- right only while the frame being copied has a rectangle to read - and it is built during
-- the first MAIL_SHOW, before Blizzard has laid the inbox out, so the first draw always got
-- the fallback numbers. An anchor has no such window: it is a relationship the layout engine
-- resolves whenever it next runs, so a row anchored to a MailItem that has never been drawn
-- still lands on it the moment it is.
--
-- Seven rows and page buttons, not twelve rows and a scroll bar. The inbox holds seven
-- letters a page and turns pages with InboxPrevPageButton and InboxNextPageButton; a list
-- that scrolls instead is a different frame however well its rows are placed. There is no
-- cap on how many offers are listed: they page.
--
-- Locked offers are shown, not hidden. An offer you cannot claim yet is the one worth
-- knowing about - a level 10 reward is only useful to somebody who is level 8.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Reward = GBA.Reward

local List = {}
ns.RewardList = List

-- What the inbox holds on one page. Blizzard's own constant if this client has it, because
-- a client that shows a different number of letters should show the same number of offers.
local PER_PAGE = _G.INBOXITEMS_TO_DISPLAY or 7

-- Only reached when the mail frame is absent entirely, which means the standalone window
-- is up on a client that could not take a tab.
local FALLBACK_ROW = { x = 13, y = -70, step = 45, width = 305, height = 45 }

local function catalog()
    return ns.rewardCatalog
end

-- Sorted the way a player reads them: what they can claim now, first. Within that, the
-- better tier first, because that is the one they came for.
local function offers()
    local list = catalog() and catalog():list() or {}
    local actor = ns.actor and ns.actor() or {}

    local rows = {}
    for _, reward in ipairs(list) do
        -- Offers meant for someone else are not listed. Their poster always sees them, to
        -- edit them and deal with their claims.
        -- Hard-list switches live in the Zone quests list instead, so a quest is never shown twice.
        if reward.hardID then
            -- listed by zoneQuests()
        elseif GBA.inGuild(reward.issuer) == false then
            -- Its poster has left the guild: nobody is left to decide a claim on it (G2).
        elseif Reward.inAudience(reward, actor) or Reward.issuerMatches(reward.issuer, actor.name or "") then
            local unlocked, unmet = Reward.gate(reward, actor)
            rows[#rows + 1] = { reward = reward, unlocked = unlocked, unmet = unmet }
        end
    end

    table.sort(rows, function(a, b)
        if a.unlocked ~= b.unlocked then return a.unlocked end
        local qa, qb = a.reward.quality or 1, b.reward.quality or 1
        if qa ~= qb then return qa > qb end
        return tostring(a.reward.title) < tostring(b.reward.title)
    end)

    -- Every offer, paged like the inbox. There used to be a cap of twelve across all officers,
    -- borrowed from the twelve attachments of one mail; it hid the thirteenth offer with no way
    -- to reach it (docs/fix-plan.md, DEC-8).
    return rows
end

-- The guild quests for the zone the player is standing in (ZoneQuests.lua), in the same row
-- shape as offers, so the rows, pages and detail view serve both lists.
local function zoneRows()
    local rows = {}
    for _, row in ipairs(ns.zoneQuests and ns.zoneQuests() or {}) do
        rows[#rows + 1] = { reward = row.reward, unlocked = row.unlocked, unmet = row.unmet, quest = row }
    end
    return rows
end

-- The offer's icon, or the nearest honest thing to one.
local function iconFor(reward)
    if reward.icon then return reward.icon end

    -- Borrow the first item the offer hands over. An offer for a sword should look like
    -- that sword without an officer having to say so twice.
    for _, give in ipairs(reward.gives or {}) do
        if give.itemID and type(GetItemInfo) == "function" then
            local texture = select(10, GetItemInfo(give.itemID))
            if texture then return texture end
        end
    end

    -- And failing that, whatever the inbox puts on a letter. Read off MailItem1's own icon
    -- rather than named, so an offer with nothing to show looks like the mail it is sitting
    -- among instead of like an addon's placeholder.
    local letter = _G.MailItem1ButtonIcon
    if letter and letter.GetTexture then return letter:GetTexture() end
    return "Interface\\Icons\\INV_Letter_15"
end

-- Painting a row ---------------------------------------------------------------

-- Each of these may be absent: the parts are discovered by name off the template rather
-- than assumed, and a client that names them differently leaves the field nil. /gba uiprobe
-- prints which ones answered. Writing through these helpers means a missing part is a blank
-- line rather than an error.
local function setText(region, text, r, g, b)
    if not region or not region.SetText then return end
    region:SetText(text or "")
    if r and region.SetTextColor then region:SetTextColor(r, g, b) end
end

-- The template's icon button starts hidden: Blizzard's inbox shows it only for a letter, and
-- nothing here ever did, so every icon set on it - a picked one, an item's, the letter's - sat
-- on a hidden button (/gba mailtree, 2026-10-01: GuildLedgerMailItem1Button hidden, its icon set).
-- Shown, it must not take the mouse: it still carries the inbox's own click and hover scripts,
-- which read Blizzard's mail by row number. The row under it handles both.
-- Only the icon: the button's cash-on-delivery tag and its backing (shown by the inbox for a COD
-- letter, and by nothing for an offer) and the quality ring stay hidden. Found by name off the
-- button, as the template names them.
local SLOT_EXTRAS = { "COD", "CODBackground", "IconBorder" }

local function showSlot(button)
    if button.EnableMouse then button:EnableMouse(false) end
    if button.SetChecked then button:SetChecked(false) end
    local name = button.GetName and button:GetName()
    for _, suffix in ipairs(SLOT_EXTRAS) do
        local region = name and _G[name .. suffix]
        if region and region.Hide then region:Hide() end
    end
    button:Show()
end

local function paintRow(row, entry)
    local parts = row.parts or {}

    -- An empty row stays on screen as an empty stub, the way the inbox keeps seven slots
    -- whether it holds seven letters or none, and like the inbox's it has no icon slot.
    if not entry then
        row.reward, row.unmet = nil, nil
        if parts.button then parts.button:Hide() end
        if parts.icon then parts.icon:Hide() end
        setText(parts.subject, "")
        setText(parts.sender, "")
        setText(parts.expires, "")
        setText(parts.count, "")
        row:Show()
        return
    end

    local reward = entry.reward
    row.reward = reward
    row.unmet = entry.unmet

    -- Onto the BUTTON's normal texture, not just the icon region.
    --
    -- Setting $parentButtonIcon alone did nothing visible: the row kept showing the engraved
    -- empty-slot rune, because that rune is the button's normal texture and it draws over an
    -- icon sitting in the same layer. Skin.setSlot learned this once already - "the item
    -- becomes the button's NORMAL texture, replacing the rune... drawing the icon as a
    -- separate layer on top is what clipped it to a sliver" - and the composer's icon slot
    -- learned it again. Both regions are set here because which one a given client's
    -- MailItemTemplate actually draws is not worth guessing at.
    local texture = iconFor(reward)
    if parts.button then
        pcall(parts.button.SetNormalTexture, parts.button, texture)
        showSlot(parts.button)
    end
    if parts.icon then
        parts.icon:SetTexture(texture)
        parts.icon:Show()
        if parts.icon.SetDesaturated then
            parts.icon:SetDesaturated(not entry.unlocked)
        end
    end

    local r, g, b = ns.Skin.qualityColor(reward.quality)

    -- Sender and subject, mapped onto what a letter carries rather than invented: an offer
    -- has somebody who posted it and a name, which is exactly what those two lines are for.
    setText(parts.sender, tostring(reward.issuer or ""))
    if entry.unlocked then
        setText(parts.subject, reward.title, r, g, b)
    else
        -- Dimmed rather than greyed flat: the tier is still readable, which is what makes
        -- a locked legendary worth working toward.
        setText(parts.subject, reward.title, r * 0.55, g * 0.55, b * 0.55)
    end

    -- Where a letter counts down to being returned, an offer says what is stopping it -
    -- or, when nothing is, what it is for. Somebody looking at a reward they cannot claim
    -- wants the reason before the joke.
    local claimed = ns.claimFor and ns.claimFor(reward.id)
    if claimed then
        -- Claimed already: that is what the player most needs to know about this row.
        local word = claimed.requeued and "Open to you again"
            or claimed.state == GBA.Reward.state.settled and "Claimed - awarded"
            or claimed.state == GBA.Reward.state.declined and "Claimed - declined"
            or "Claimed"
        setText(parts.expires, word, 0.45, 0.85, 0.45)
    elseif entry.quest then
        -- A guild quest's line says only Accepted or Completed, and nothing until it is taken.
        -- How far along it is belongs to the tracker and the quest log.
        local quest = entry.quest
        if quest.state == "offer" then
            setText(parts.expires, "")
        elseif quest.progress and quest.progress.done then
            setText(parts.expires, "Completed", 0.45, 0.85, 0.45)
        else
            setText(parts.expires, "Accepted", 0.72, 0.68, 0.58)
        end
    elseif entry.unlocked then
        setText(parts.expires, reward.flavor or "", 0.72, 0.68, 0.58)
    else
        setText(parts.expires, entry.unmet[1] or "locked", 0.85, 0.35, 0.3)
    end

    setText(parts.count, "")
    row:Show()
end

local function rowTooltip(row)
    if not row.reward then return end
    local reward = row.reward
    local names = GBA.Resolve.live(GBA.spokes)

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local r, g, b = ns.Skin.qualityColor(reward.quality)
    GameTooltip:AddLine(reward.title, r, g, b)
    if reward.flavor then GameTooltip:AddLine(reward.flavor, 0.8, 0.78, 0.7, true) end

    local wants = Reward.describeEntries(reward.wants, GBA.Resolve, names)
    local gives = Reward.describeEntries(reward.gives, GBA.Resolve, names)
    if wants then GameTooltip:AddLine("Hand in: " .. wants, 1, 1, 1, true) end
    if gives then GameTooltip:AddLine("You get: " .. gives, 1, 1, 1, true) end

    if row.unmet and #row.unmet > 0 then
        GameTooltip:AddLine(" ")
        for _, why in ipairs(row.unmet) do
            GameTooltip:AddLine(why, 0.9, 0.3, 0.25, true)
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Attaches: " .. Reward.describeAttachment(reward.attach), 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

-- Build --------------------------------------------------------------------------

function List.build(parent, width, height)
    ns.Skin.load()

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width, height)
    frame.page = 1

    -- No sheet. The inbox has not got one, and neither has this.
    --
    -- Two wrong answers came before that one. The first cut a sheet from the row block with
    -- margins chosen by eye. The second anchored a sheet to InboxFrameBg, on the strength of
    -- /gba uiprobe finding a parchment at fileID 530419 on that region - and the wireframe
    -- then reported both it and our sheet as "not placed", because the region carries a
    -- texture and no rectangle. Anchored to it and sized by hand, the sheet drew a patch of
    -- bright parchment across part of the list and left the rest bare: copyTexture brings the
    -- source's texture COORDINATES with it, and that crop does not fill a rectangle Blizzard
    -- never drew it in.
    --
    -- A region with art and no anchors is one the client does not use. Classic Era's mail
    -- frame papers its inbox with MailFrameBg and the art each MailItem carries - and the
    -- rows here ARE MailItems now, so that background arrives with them. The sheet was a
    -- leftover from when these rows were drawn by hand and needed something underneath.
    --
    -- The standalone window still lays one, in RewardsPanel.openWindow: there is no mail
    -- frame behind it to supply the stone.

    -- Rows, from Blizzard's template, one per letter slot. The count is fixed at build
    -- because rows are frames; the page turns instead.
    frame.rows = {}
    for index = 1, PER_PAGE do
        local row = ns.Skin.rowButton(frame, "GuildLedgerMailItem" .. index)
        row:SetScript("OnEnter", rowTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if not self.reward then return end
            if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION or 88) end
            ns.RewardsPanel.showDetail(self.reward)
        end)
        row:Hide()
        frame.rows[index] = row
    end

    -- Page buttons, wearing the inbox's own arrows. Built as plain buttons and then dressed
    -- from InboxPrevPageButton: there is no template name to inherit here, and copying all
    -- four states rather than the resting one is what stops them blanking on the first click.
    local function pageButton(name, source, step)
        local button = CreateFrame("Button", name, frame)
        button:SetSize(32, 32)
        ns.Skin.copyButton(button, source)
        button:SetScript("OnClick", function()
            if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION or 88) end
            frame.page = frame.page + step
            frame:refresh()
        end)
        return button
    end

    frame.prev = pageButton("GuildLedgerPrevPage", "InboxPrevPageButton", -1)
    frame.next = pageButton("GuildLedgerNextPage", "InboxNextPageButton", 1)

    -- Where the inbox keeps its page number, in the inbox's own font.
    frame.pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local currentPage = _G.InboxCurrentPage
    if currentPage and currentPage.GetFontObject and currentPage:GetFontObject() then
        frame.pageText:SetFontObject(currentPage:GetFontObject())
    end

    frame.empty = frame:CreateFontString(nil, "OVERLAY", ns.Skin.fonts.body)
    frame.empty:SetJustifyH("LEFT")
    frame.empty:SetTextColor(0.3, 0.24, 0.16)

    -- Anchoring, all of it. Re-run on every refresh rather than once at build: the panel can
    -- move between the mail frame and the standalone window, and which of those it is in
    -- decides whether these anchor onto Blizzard's frames or onto measured offsets.
    function frame:anchorAll()
        local panel = self:GetParent()

        for index, row in ipairs(self.rows) do
            local source = _G["MailItem" .. index]
            ns.Skin.anchorTo(row, "MailItem" .. index, panel, 0, 0, {
                x = FALLBACK_ROW.x,
                y = FALLBACK_ROW.y - (index - 1) * FALLBACK_ROW.step,
            })
            if source and source.GetWidth and (source:GetWidth() or 0) > 1 then
                row:SetSize(source:GetWidth(), source:GetHeight())
            else
                row:SetSize(FALLBACK_ROW.width, FALLBACK_ROW.height)
            end
        end

        ns.Skin.anchorTo(self.prev, "InboxPrevPageButton", panel, 0, 0, { x = 14, y = -382 })
        ns.Skin.anchorTo(self.next, "InboxNextPageButton", panel, 0, 0, { x = 289, y = -382 })

        -- Looked up here rather than held from build: this is Blizzard's region, and holding
        -- a reference taken before the mailbox had drawn itself is the same class of mistake
        -- as holding a coordinate taken then.
        -- On OpenAllMail's line, not InboxCurrentPage's.
        --
        -- InboxCurrentPage measures 82,-415 192x1 - it sits below the page buttons, where
        -- the inbox has nothing else to put. The strip our page number wants is the one
        -- Blizzard fills with Open All, at -398, between the two arrows. We have no Open
        -- All, so that space is ours and it is where the eye already goes.
        local page = _G.OpenAllMail or _G.InboxCurrentPage
        self.pageText:ClearAllPoints()
        if page and panel.embedded ~= false then
            self.pageText:SetPoint("CENTER", page, "CENTER", 0, 0)
        else
            self.pageText:SetPoint("TOP", self.prev, "BOTTOM", 0, -2)
        end

        -- The empty line goes on the first row's own rectangle, which is where a player
        -- looking for their first offer is already looking.
        self.empty:ClearAllPoints()
        self.empty:SetPoint("TOPLEFT", self.rows[1], "TOPLEFT", 6, -12)
        self.empty:SetWidth(math.max(80, (self.rows[1]:GetWidth() or FALLBACK_ROW.width) - 12))
    end

    List.frame = frame
    frame:anchorAll()

    function frame:refresh()
        self:anchorAll()

        local rows
        if self.mode == "zone" then rows = zoneRows() else rows = offers() end
        local pages = math.max(1, math.ceil(#rows / PER_PAGE))

        -- Clamped rather than trusted. An offer claimed off the second page leaves the list
        -- one page long with the view still on page two, which would otherwise paint seven
        -- empty rows and look like everything vanished.
        if self.page > pages then self.page = pages end
        if self.page < 1 then self.page = 1 end

        -- Nothing to list: no rows at all, so the message reads on clear paper instead of under
        -- seven empty slots.
        local offset = (self.page - 1) * PER_PAGE
        for index = 1, PER_PAGE do
            if #rows == 0 then
                self.rows[index].reward, self.rows[index].unmet = nil, nil
                self.rows[index]:Hide()
            else
                paintRow(self.rows[index], rows[index + offset])
            end
        end

        if #rows == 0 and self.mode == "zone" then
            self.empty:SetText("No guild quests here yet."
                .. "\n\nOfficers switch them on zone by zone. Each zone has its own, so look"
                .. " again at the next mailbox you pass.")
            self.empty:Show()
        elseif #rows == 0 then
            -- Rewards go out while their officer is online, and nothing queues them: an empty list
            -- asks the officers online for the current one, at most every five minutes.
            local now = time()
            local asked = 0
            if ns.askRewards and now - (List.askedAt or 0) >= 300 then
                List.askedAt = now
                asked = ns.askRewards(true)
            end
            self.empty:SetText("Nothing on offer yet."
                .. (asked > 0 and "\n\nAsking the officers online for the current rewards..."
                    or "\n\nOfficers post rewards to the guild. The list is asked for again when"
                        .. " you open this while an officer is online."))
            self.empty:Show()
        else
            self.empty:Hide()
        end

        -- The buttons stay on screen and go dim, which is what the inbox's do. Hiding them
        -- would move the page number and make a one-page list a different shape.
        if self.page > 1 then self.prev:Enable() else self.prev:Disable() end
        if self.page < pages then self.next:Enable() else self.next:Disable() end

        -- Blizzard's own page wording where the client has it. Guarded, because a locale
        -- whose string carries a different number of format specifiers would otherwise
        -- error here rather than merely read oddly.
        local ok, text = pcall(string.format, _G.MERCHANT_PAGE_NUMBER or "Page %d", self.page)
        if not ok then text = "Page " .. self.page end
        self.pageText:SetText(text)
    end

    -- The wheel turns pages too. The inbox has no wheel handler, so this adds nothing
    -- visible; it just means the gesture a list invites does the thing it looks like.
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(self, delta)
        self.page = self.page - delta
        self:refresh()
    end)

    return frame
end
