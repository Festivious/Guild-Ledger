-- The Rewards tab, claim view: one offer, opened, laid out as the Send Mail frame.
--
-- Not "styled like" it - measured off it. Claiming IS sending mail: the player hands items
-- to an officer, and the frame that does that in this game is Send Mail. So the recipient
-- sits where To sits, the subject where Subject sits, the offer's words on the letter's own
-- stationery, the items in a row of attachment slots beneath it, and Claim where Send is
-- with Back where Cancel is.
--
-- Every one of those positions is read off Blizzard's frames at runtime
-- (sendMailGeometry), for the same reason the list reads MailItem: a number typed in here
-- is right until the first time it is not, and this tab has already been wrong four times
-- that way. When the send mail frame cannot be measured - which means the mailbox is shut -
-- the fallback is a plain stack in the same order.
--
-- The body content itself is unchanged. It was right.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Reward, Resolve = GBA.Reward, GBA.Resolve

local Detail = {}
ns.RewardDetail = Detail

local ITEM_SIZE = 37
local LINE_GAP = 3

-- The offer the claim view is showing. File-local on purpose: Detail.show sets it and
-- Detail.refresh reads it, and a global called "current" is a collision waiting for whatever
-- other addon has the same idea.
local current

-- Sessions, newest first. sessionID is the login timestamp, so it sorts chronologically.
local function sessionChoices()
    local out = {}
    for id, context in pairs(ns.sessions or {}) do
        out[#out + 1] = { id = id, context = context }
    end
    table.sort(out, function(a, b) return a.id > b.id end)
    return out
end

-- Send Mail's own furniture -------------------------------------------------------

-- Where each part goes, as an anchor onto the Blizzard frame it stands in for.
--
-- This replaced measuring, and the reason is worth keeping. The old sendMailGeometry read
-- GetLeft off each send-mail frame and copied the numbers into SetPoint calls of its own,
-- which works only once that frame has been laid out - and /gba wireframe found
-- SendMailBodyEditBox and SendMailScrollFrame reporting no rectangle at all on this client,
-- because a frame the player has never opened has never been through a layout pass. Every
-- one of those turned into a silent fall back to invented numbers.
--
-- An anchor has no such window. It is a relationship the layout engine resolves whenever it
-- next runs, so a part anchored to a frame that has not been drawn yet still lands on it the
-- moment it is - and moves with it afterwards, which copied numbers never did.
--
-- `fallback` is used only when the client has no such frame at all, which is a different
-- case from having one somewhere else.
local function pointTo(target, spec)
    local source = _G[spec.source]
    local panel = spec.panel
    target:ClearAllPoints()

    -- Placed, not merely present - see Skin.anchorTo for what that distinction cost.
    if source and (not panel or panel.embedded ~= false)
        and source.GetLeft and source:GetLeft() then
        target:SetPoint(spec.point, source, spec.rel or spec.point, spec.dx or 0, spec.dy or 0)
        return true
    end

    -- Standing alone in its own window, our panel is not over the mailbox, so Blizzard's
    -- frames are no use as anchors. Their offsets against MailFrame are stable, though, so
    -- those are laid onto the panel instead.
    local mail = _G.MailFrame
    if source and panel and mail and source.GetLeft and source:GetLeft() and mail:GetLeft() then
        target:SetPoint("TOPLEFT", panel, "TOPLEFT",
            math.floor(source:GetLeft() - mail:GetLeft() + 0.5) + (spec.dx or 0),
            math.floor(source:GetTop() - mail:GetTop() + 0.5) + (spec.dy or 0))
        return true
    end

    local fallback = spec.fallback or { x = 0, y = 0 }
    target:SetPoint(fallback.point or "TOPLEFT", panel or target:GetParent(), "TOPLEFT",
        fallback.x or 0, fallback.y or 0)
    return false
end

-- The shape Send Mail has, in numbers, for a client that has none of these frames. Measured
-- off this one with /gba wireframe rather than chosen, so a client that falls back gets the
-- layout this one has rather than a guess at it.
local FALLBACK = {
    name    = { x = 90,  y = -30, w = 109, h = 25 },
    subject = { x = 90,  y = -55, w = 220, h = 20 },
    body    = { x = 8,   y = -82, w = 316, h = 198 },
    slot    = { x = 15,  y = -297 },
    money   = { x = 15,  y = -345 },
    send    = { x = 171, y = -398, w = 80, h = 22 },
    board   = { x = 4,   y = -397, w = 166, h = 23 },
    cancel  = { x = 251, y = -398, w = 80, h = 22 },
}

-- Body lines ------------------------------------------------------------------

-- A pool, grown as needed and hidden when not. Same shape as QuestInfoObjective1..10:
-- each line anchored under the one above, all of them the same small font.
local function lineAt(frame, index)
    local lines = frame.lines
    if not lines[index] then
        local line = frame.child:CreateFontString(nil, "OVERLAY", ns.Skin.fonts.objective)
        line:SetWidth(frame.bodyWidth)
        line:SetJustifyH("LEFT")
        line:SetSpacing(2)
        lines[index] = line
    end
    return lines[index]
end

local function layoutLines(frame, entries)
    local y = 0
    for index, entry in ipairs(entries) do
        local line = lineAt(frame, index)
        -- Re-widened on every layout, not just when the line was created. These are pooled
        -- and reused, so a line first drawn while the page had not been measured keeps that
        -- width for the rest of the session - and a line 30 units wide wraps its text to
        -- three characters a row, which is what the garbled column was.
        line:SetText(entry.text)
        line:SetTextColor(entry.r or 0.16, entry.g or 0.12, entry.b or 0.06)
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", frame.child, "TOPLEFT", entry.indent or 0, -y)
        line:Show()
        y = y + line:GetStringHeight() + (entry.gap or LINE_GAP)
    end
    for index = #entries + 1, #frame.lines do
        frame.lines[index]:Hide()
    end
    return y
end

-- Reward icons, inside the body ------------------------------------------------

local function itemButton(frame, index)
    local buttons = frame.items
    if not buttons[index] then
        buttons[index] = ns.Skin.itemButton(frame.child,
            "GuildLedgerDetailItem" .. index, ITEM_SIZE)
    end
    return buttons[index]
end

-- Lays the `gives` items out as a row of icons and returns how tall it came to.
local function layoutItems(frame, reward, y)
    local shown = 0
    local perRow = math.max(1, math.floor(frame.bodyWidth / (ITEM_SIZE + 6)))

    for _, give in ipairs(reward.gives or {}) do
        if give.itemID and shown < Reward.MAX_GIVES then
            shown = shown + 1
            local button = itemButton(frame, shown)
            local row = math.floor((shown - 1) / perRow)
            local column = (shown - 1) % perRow
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", frame.child, "TOPLEFT",
                column * (ITEM_SIZE + 6), -(y + row * (ITEM_SIZE + 6)))

            local quality
            if type(GetItemInfo) == "function" then
                quality = select(3, GetItemInfo(give.itemID))
            end
            ns.Skin.setItem(button, give.itemID, give.quantity, quality)
        end
    end

    for index = shown + 1, #frame.items do
        frame.items[index]:Hide()
    end

    if shown == 0 then return 0 end
    return math.ceil(shown / perRow) * (ITEM_SIZE + 6)
end

-- The attachment row is gone, and with it the borrowing --------------------------
--
-- This view used to reparent SendMailAttachment1..12 into itself while it was shown and hand
-- them back on hide. That was the riskiest thing in this tab: a button left parented to a
-- hidden frame of ours is a button missing from Send Mail, which would break posting mail
-- for the rest of the session.
--
-- It is gone because the row was saying the same thing twice. Reward.bodyLines already lists
-- what to hand in, in words, in the letter - and the real attachment row appears a moment
-- later in Send Mail itself, filled, when the claim is made. A preview of it underneath the
-- letter bought nothing and cost that.
--
-- The strip it occupied now holds what the offer asks the player to SHARE, which is the one
-- thing on this frame the letter cannot say for itself.

-- Placing everything against it ---------------------------------------------------

-- Moves every part onto the Blizzard frame it stands in for.
--
-- Called on every show rather than once at build, and it used to be for a reason that no
-- longer applies: at build time - the first MAIL_SHOW of a session - the send mail frame has
-- never been drawn, so measuring it returned nothing and the whole view silently used its
-- fallback. Anchors do not have that failure, so this is now merely cheap and idempotent.
-- It still runs on every show because the panel can move between the mail frame and the
-- standalone window, and which of those it is in decides what these anchor to.
local function anchorAll(frame)
    local panel = frame:GetParent()

    -- From and Subject, on the two edit boxes Send Mail keeps To and Subject in.
    -- Our box ON Blizzard's box, corner to corner and the same size. Ours IS the field now,
    -- so there is no inset to add: the +6,-6 the old code used was a fontstring being placed
    -- inside a box it was only pretending to sit in.
    --
    -- Sized from Blizzard's rather than run out to the panel edge, which is a real trade and
    -- worth naming: the name box is 109 units, and an issuer like "Crashdummy-Skull Rock"
    -- does not fit in 109. It clips, exactly as a long recipient clips in Send Mail's own To
    -- field, and Skin.setInput winds the cursor back so what shows is the start of the name
    -- rather than the end of it. The alternative is a box wider than the one it is copying,
    -- which is the thing this whole tab is trying not to be.
    local function headerRow(label, box, boxName, fallback)
        local source = _G[boxName]
        pointTo(box, {
            point = "TOPLEFT", source = boxName, rel = "TOPLEFT",
            panel = panel, fallback = fallback,
        })
        if source and source.GetWidth and (source:GetWidth() or 0) > 1 then
            box:SetSize(source:GetWidth(), source:GetHeight())
        else
            box:SetSize(fallback.w or 109, fallback.h or 25)
        end

        -- Where Send Mail's "To:" goes: 6 units left of the box, right-aligned to it.
        label:ClearAllPoints()
        label:SetPoint("RIGHT", box, "LEFT", -6, 0)
    end

    headerRow(frame.fromLabel, frame.sender, "SendMailNameEditBox", FALLBACK.name)
    headerRow(frame.subjectLabel, frame.subject, "SendMailSubjectEditBox", FALLBACK.subject)

    -- The letter's page: the two stationery halves, taken as the one rectangle they make.
    --
    -- Anchored by one corner and then SIZED, rather than pinned by both. Pinning both
    -- corners is what a rectangle wants, but a frame sized that way does not report its
    -- size to GetWidth until a layout pass has run - and the parchment splits its two halves
    -- at a pixel offset computed from exactly that width. Blizzard's own widths are stable
    -- and readable, so they are what the size comes from.
    local left, right = _G.SendStationeryBackgroundLeft, _G.SendStationeryBackgroundRight
    local pageWidth, pageHeight = FALLBACK.body.w, FALLBACK.body.h
    if left and left.GetWidth and (left:GetWidth() or 0) > 1 then
        pageWidth = math.floor(left:GetWidth() + ((right and right:GetWidth()) or 0) + 0.5)
        pageHeight = math.floor(left:GetHeight() + 0.5)
    end

    ns.Skin.anchorTo(frame.paper, "SendStationeryBackgroundLeft", panel, 0, 0, FALLBACK.body)
    frame.paper:SetSize(pageWidth, pageHeight)

    -- Re-cut only when the page actually changed size. Forcing it every refresh re-anchors
    -- both halves for nothing; never forcing it leaves the tear in the wrong place the first
    -- time the page grows from nothing to its real width.
    local stamp = pageWidth .. "x" .. pageHeight
    if frame.paperStamp ~= stamp then
        frame.paperStamp = stamp
        ns.Skin.redress(frame.paper, true)
    end

    -- The writing area, which is NOT the page.
    --
    -- The page is 8,-82 316x198; the area a letter is actually written in is MailEditBox at
    -- 28,-93 268x190, inset from it. Every earlier version guessed that inset as +12,-6 off
    -- the paper and was eight units left and fourteen wide - which is what made the body
    -- text sit wrong however well the paper was placed.
    local BODY = { x = 28, y = -93, w = 268, h = 190 }
    local editBox = _G.MailEditBox
    local bodyW = (editBox and editBox.GetWidth and (editBox:GetWidth() or 0) > 1)
        and math.floor(editBox:GetWidth() + 0.5) or BODY.w
    local bodyH = (editBox and editBox.GetHeight and (editBox:GetHeight() or 0) > 1)
        and math.floor(editBox:GetHeight() + 0.5) or BODY.h

    ns.Skin.anchorTo(frame.scroll, "MailEditBox", panel, 0, 0, BODY)
    frame.scroll:SetSize(bodyW, bodyH)

    -- The bar is Blizzard's, borrowed, not built.
    --
    -- What used to be here raised a bar off UIPanelScrollFrameTemplate, painted the mail
    -- frame's thumb onto it and parked it at a measured offset. Every part of that was an
    -- approximation of a widget sitting three inches away on the same screen, and the
    -- leftovers - the track's end caps, the arrows' overhang, the recess they sit in - were
    -- never going to come across one texture at a time.
    --
    -- MailTabs.lendScrollBar moves the real one onto frame.scroll instead, and how it
    -- stays working once it is here depends on which kind of widget this client's bar turns
    -- out to be - MailTabs asks the widget and wires it accordingly. Either way the arrows,
    -- the wheel and the thumb drive OUR body afterwards, and uncoverAll hands the bar back
    -- the moment this tab stops wearing Send Mail.
    local lent, why = GBA.MailTabs.lendScrollBar(frame.scroll)
    if not lent then
        -- A client with no mail bar to borrow still gets a working body. This is the old
        -- path, kept whole as the fallback it always should have been.
        local bar = frame.scroll.ScrollBar or _G["GuildLedgerDetailBodyScrollBar"]
        if bar then
            if GBA.MailTabs.dressScrollBar then GBA.MailTabs.dressScrollBar(bar) end
            ns.Skin.anchorTo(bar, "MailEditBoxScrollBar", panel, 4, -20, { x = 307, y = -99 })
        end
        ns.Skin.using.scrollBar = "own bar (" .. tostring(why) .. ")"
    else
        ns.Skin.using.scrollBar = "borrowed from the mail frame"
    end

    frame.bodyWidth = bodyW - 6
    frame.child:SetWidth(bodyW)
    for _, line in ipairs(frame.lines) do line:SetWidth(frame.bodyWidth) end

    -- The attachment slots, one anchor each, so ours wrap however Blizzard's wrap without
    -- this code knowing the arrangement.
    --
    -- The strip under the page: what this offer asks to be shared.
    frame.dataLabel:ClearAllPoints()
    frame.dataLabel:SetPoint("TOPLEFT", frame.paper, "BOTTOMLEFT", 6, -6)

    local column = math.floor((frame.paper:GetWidth() - 12) / 2)
    for index, row in ipairs(frame.dataRows) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.dataLabel, "BOTTOMLEFT",
            (index > 4 and column or 0), -2 - ((index - 1) % 4) * 18)
        row:SetWidth(column - 8)
    end

    -- Under the slots, in the order picker then money then consent.
    --
    -- The gap is tight and the ordering is what makes it fit: 64 units between the foot of
    -- the slot row and the top of the buttons. Stacking the other way round - consent pinned
    -- to the money strip, picker growing down from the slots - put the picker at -386 running
    -- to -418, twenty units through Claim and Back, which the wireframe caught as
    -- detail.session -1,-386 308x32.
    --
    -- A dropdown draws about 16 units left of where it is anchored, which is why it is pulled
    -- back by that much rather than sitting flush with the slot column.
    frame.sessions:ClearAllPoints()
    frame.sessions:SetPoint("TOPLEFT", frame.dataLabel, "BOTTOMLEFT", -16, -2 - 4 * 18)

    -- The money row goes on the strip Send Mail keeps its own on, and only when there is gold
    -- to show. Send Mail shows the row always because it is asking; ours is answering, and an
    -- "Amount to send: 0" on every claim is noise in the one place the frame has none to
    -- spare - there are 64 units between the slots and the buttons.
    --
    -- Label and amount on ONE line, where Blizzard stacks a label over three boxes. Three
    -- boxes need the height; a figure does not, and the line below it has to fit too.
    local showMoney = (frame.copperWanted or 0) > 0
    frame.sendLabel:SetShown(showMoney)
    frame.sendMoney:SetShown(showMoney)

    if showMoney then
        local _, moneyAnchor = ns.Skin.firstOf("SendMailMoneyText", "SendMailMoneyFrame",
            "SendMailCostMoneyFrame", "SendMailHorizontalBarLeft")
        pointTo(frame.sendLabel, {
            point = "TOPLEFT", source = moneyAnchor or "?", rel = "TOPLEFT", dx = 0, dy = -2,
            panel = panel, fallback = FALLBACK.money,
        })
        frame.sendMoney:ClearAllPoints()
        frame.sendMoney:SetPoint("LEFT", frame.sendLabel, "RIGHT", 8, 0)
    end

    -- The picker, when there is one, takes the footer's place rather than pushing it down:
    -- there are 118 units between the page and the buttons and the list already spends 90.
    if frame.sessions:IsShown() then
        frame.consent:Hide()
    elseif showMoney then
        frame.consent:ClearAllPoints()
        frame.consent:SetPoint("TOPLEFT", frame.sendLabel, "BOTTOMLEFT", 0, -6)
    else
        local _, moneySource = ns.Skin.firstOf("SendMailMoneyText", "SendMailMoneyFrame",
            "SendMailCostMoneyFrame", "SendMailHorizontalBarLeft")
        pointTo(frame.consent, {
            point = "TOPLEFT", source = moneySource or "?", rel = "TOPLEFT", dx = 0, dy = -2,
            panel = panel, fallback = FALLBACK.money,
        })
    end
    frame.consent:SetWidth(math.max(80, frame.paper:GetWidth() - 12))

    -- Claim where Send is, Back where Cancel is.
    for _, spec in ipairs({
        { button = frame.claim, source = "SendMailMailButton",   fallback = FALLBACK.send },
        { button = frame.back,  source = "SendMailCancelButton", fallback = FALLBACK.cancel },
    }) do
        local source = _G[spec.source]
        if source and source.GetWidth and (source:GetWidth() or 0) > 1 then
            spec.button:SetSize(source:GetWidth(), source:GetHeight())
        else
            spec.button:SetSize(spec.fallback.w, spec.fallback.h)
        end
        pointTo(spec.button, {
            point = "TOPLEFT", source = spec.source, rel = "TOPLEFT",
            panel = panel, fallback = spec.fallback,
        })
    end

    -- The poster's buttons - Claims, Edit, Remove - in a well of their own where Send Mail keeps
    -- its money box, the way Claim and Back stand where Send and Cancel do: one bar of buttons,
    -- each in a well. Whichever are shown share it equally.
    local board = frame.board
    local source = _G.SendMailMoneyInset
    if source and source.GetWidth and (source:GetWidth() or 0) > 1 then
        board:SetSize(source:GetWidth(), source:GetHeight())
    else
        board:SetSize(FALLBACK.board.w, FALLBACK.board.h)
    end
    pointTo(board, { point = "TOPLEFT", source = "SendMailMoneyInset", rel = "TOPLEFT",
        panel = panel, fallback = FALLBACK.board })
    local shown = {}
    for _, button in ipairs({ frame.claims, frame.edit, frame.remove }) do
        if button:IsShown() then shown[#shown + 1] = button end
    end
    board:SetShown(#shown > 0)
    local gap = 2
    local width = math.floor((board:GetWidth() - gap * (#shown + 1)) / math.max(1, #shown))
    for i, button in ipairs(shown) do
        button:ClearAllPoints()
        button:SetSize(width, board:GetHeight() - 1)
        button:SetPoint("TOPLEFT", board, "TOPLEFT", gap + (i - 1) * (width + gap), 0)
        button:SetFrameLevel(board:GetFrameLevel() + 2)
        -- Three to a well leaves no room for the big font.
        local font = width < 70 and "GameFontNormalSmall" or "GameFontNormal"
        button:SetNormalFontObject(font)
        button:SetHighlightFontObject(width < 70 and "GameFontHighlightSmall" or "GameFontHighlight")
        button:SetDisabledFontObject(width < 70 and "GameFontDisableSmall" or "GameFontDisable")
    end
end

-- Build ------------------------------------------------------------------------

function Detail.build(parent, width, height)
    ns.Skin.load()

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width, height)
    frame.lines = {}
    frame.items = {}
    frame.width, frame.height = width, height

    -- Blizzard's attachment buttons are reparented in while this view is up, so they have to
    -- go back the moment it is not. OnHide fires when an ancestor is hidden too, which covers
    -- the tab being switched away from and the mailbox being closed, not just Back.

    -- Everything below is created unplaced. anchorAll puts it where Send Mail keeps
    -- its equivalent, on every show.

    local function headerLabel(text)
        local label = frame:CreateFontString(nil, "OVERLAY", ns.Skin.fonts.objective)
        label:SetText(text)
        label:SetTextColor(1, 0.82, 0.3)
        return label
    end

    -- Blizzard's own boxes, not text laid where a box would be. Same treatment as the rows.
    frame.fromLabel = headerLabel("From:")
    frame.sender = ns.Skin.inputBox(frame, "GuildLedgerClaimFrom")
    frame.subjectLabel = headerLabel("Subject:")
    frame.subject = ns.Skin.inputBox(frame, "GuildLedgerClaimSubject")

    -- No title line. Send Mail has not got one, and the offer's name goes where a mailbox
    -- says what it is showing: the frame's own title bar, via RewardsPanel.setTitle.

    -- The letter's own page, and the offer's words on it.
    frame.paper = ns.Skin.sheet(frame, "stationery", -1)

    -- With the bar: this body can run longer than a page, which is the point of it being
    -- a scroll rather than a label.
    local scroll = ns.Skin.scrollBody(frame, "GuildLedgerDetailBody", 200, 100, true)
    frame.scroll = scroll
    frame.child = scroll.child
    frame.bodyWidth = 200

    -- What this offer asks to be shared, drawn from Core's list so it is the same list, in
    -- the same order, as the officer ticked on the composer's last page.
    frame.dataLabel = frame:CreateFontString(nil, "OVERLAY", ns.Skin.fonts.objective)
    frame.dataLabel:SetTextColor(1, 0.82, 0.3)

    frame.dataRows = {}
    for index = 1, #Reward.dataCategories do
        local row = frame:CreateFontString(nil, "OVERLAY", ns.Skin.fonts.objective)
        row:SetJustifyH("LEFT")
        row:SetMaxLines(1)
        frame.dataRows[index] = row
    end

    -- No label over the slot row. Send Mail has not got one, and the letter itself already
    -- carries "Hand in" as a heading over the same list in words - so the label was saying a
    -- second time what the page says once, in the 17 units between the foot of the page and
    -- the top of the slots, which is not enough room to say anything in.

    -- Send Mail's money row, for the offers that ask for gold as well as items.
    --
    -- A readout, not three coin boxes: Send Mail offers those because the player chooses the
    -- amount, and here the offer has already chosen it - typing a different number would
    -- either be ignored or break the claim. So the label is Blizzard's and the amount beside
    -- it is the coin widget the whole default UI uses.
    --
    -- And no C.O.D. Cash on delivery asks the RECIPIENT to pay, which for a reward claim
    -- would mean billing the officer for the thing they are giving away.
    frame.sendLabel = frame:CreateFontString(nil, "OVERLAY", ns.Skin.fonts.objective)
    frame.sendLabel:SetText(_G.AMOUNT_TO_SEND or "Amount to send:")
    frame.sendLabel:SetTextColor(1, 0.82, 0.3)
    frame.sendLabel:Hide()

    frame.sendMoney = ns.Skin.moneyFrame(frame)
    frame.sendMoney:Hide()

    -- What leaves the computer. Kept out of the body on purpose: it is the one privacy
    -- control an officer cannot work around, and something a player has to scroll to find
    -- is something they will not read.
    frame.consent = frame:CreateFontString(nil, "OVERLAY", ns.Skin.fonts.objective)
    frame.consent:SetJustifyH("LEFT")
    frame.consent:SetSpacing(2)
    frame.consent:SetTextColor(1, 0.82, 0.3)

    -- Which session, for the offers that ask for one.
    local sessions = CreateFrame("Frame", "GuildLedgerDetailSessions", frame,
        "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(sessions, width - 80)
    UIDropDownMenu_Initialize(sessions, function()
        for _, choice in ipairs(sessionChoices()) do
            local info = UIDropDownMenu_CreateInfo()
            local context = choice.context
            info.text = string.format("%s  level %s-%s",
                date("%d %b %H:%M", choice.id),
                tostring(context.levelAtStart), tostring(context.levelAtEnd))
            info.notCheckable = true
            info.func = function()
                ns.ClaimFlow.setSession(choice.id)
                UIDropDownMenu_SetText(sessions, info.text)
                Detail.refresh()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    frame.sessions = sessions

    -- Claim where Send is, Back where Cancel is. The two buttons a letter has, doing the
    -- two things this frame does.
    frame.claim = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.claim:SetText("Claim")
    frame.claim:SetScript("OnClick", function(self)
        if not current then return end
        -- A guild quest: accept it, abandon it, or turn it in (which is claiming, below).
        if self.mode == "accept" or self.mode == "abandon" then
            local ok, why
            if self.mode == "accept" then ok, why = ns.acceptHard(current.hardID)
            else ok, why = ns.abandonHard(current.hardID) end
            if not ok then GBA.Print("|cffffcc00" .. tostring(why) .. "|r") end
            if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN or 875) end
            return Detail.refresh()
        end
        if self.mode == "resend" then
            local ok, why = ns.resendClaim(current.id)
            GBA.Print(ok and "sending your claim's data and key letters again" or ("|cffffcc00" .. tostring(why) .. "|r"))
            return Detail.refresh()
        end
        if self.mode == "claimed" then return end
        ns.ClaimFlow.begin(current)
    end)
    if frame.claim.SetMotionScriptsWhileDisabled then
        frame.claim:SetMotionScriptsWhileDisabled(true)
    end
    frame.claim:SetScript("OnEnter", function(self)
        if not current then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if self.mode == "accept" then
            GameTooltip:AddLine("Accept this guild quest", 1, 1, 1)
            GameTooltip:AddLine("It goes into your guild quest log. Progress counts from now.", 0.7, 0.7, 0.7, true)
        elseif self.mode == "abandon" then
            GameTooltip:AddLine("Abandon", 1, 1, 1)
            GameTooltip:AddLine("Takes it out of your log. Accepting again starts it over.", 0.7, 0.7, 0.7, true)
        elseif self.mode == "resend" then
            GameTooltip:AddLine("Resend", 1, 1, 1)
            GameTooltip:AddLine("Offers your data to the officers again, and mails any key letter"
                .. " still waiting. Nothing new is claimed.", 0.7, 0.7, 0.7, true)
        elseif self.mode == "claimed" then
            GameTooltip:AddLine("Already claimed", 1, 1, 1)
            GameTooltip:AddLine("The officers have everything this claim sent.", 0.7, 0.7, 0.7, true)
        elseif self.locked then
            GameTooltip:AddLine("You cannot claim this yet", 1, 0.4, 0.3)
            for _, why in ipairs(self.unmet or {}) do
                GameTooltip:AddLine(why, 0.9, 0.7, 0.6, true)
            end
        else
            GameTooltip:AddLine("Claim this reward", 1, 1, 1)
            GameTooltip:AddLine(
                "Send Mail opens with what this asks for already attached."
                .. " Nothing is sent until you press Send.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    frame.claim:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.back = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.back:SetText("Back")
    frame.back:SetScript("OnClick", function() ns.RewardsPanel.showList() end)

    -- The poster's well (anchorAll places it and its buttons): the dark inset under Send Mail's
    -- money box, copied off its own texture, so the bar reads as one row of wells.
    frame.board = CreateFrame("Frame", nil, frame)
    local function copied(layer, name, fallback)
        local tex = frame.board:CreateTexture(nil, layer)
        local src = _G[name]
        local file = src and src.GetTexture and src:GetTexture()
        if file then
            tex:SetTexture(file)
            if src.GetTexCoord then tex:SetTexCoord(src:GetTexCoord()) end
        else
            tex:SetColorTexture(fallback[1], fallback[2], fallback[3], fallback[4])
        end
        return tex
    end
    frame.board.bg = copied("BACKGROUND", "SendMailMoneyInsetBg", { 0.05, 0.05, 0.05, 0.85 })
    frame.board.bg:SetAllPoints()
    frame.board:Hide()

    -- Edit, for the officer who posted this offer. Only the Guild addon has a composer to
    -- open, so in the member addon this button is never shown.
    frame.edit = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.edit:SetText("Edit")
    frame.edit:SetScript("OnClick", function()
        if current and ns.OfferComposer and ns.OfferComposer.edit then ns.OfferComposer.edit(current) end
    end)
    frame.edit:Hide()

    -- Remove, beside Edit (it used to sit on the composer's top line, over the level boxes).
    -- The composer asks first: a removal reaches every member and cannot be taken back.
    frame.remove = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.remove:SetText("Remove")
    frame.remove:SetScript("OnClick", function()
        if current and ns.OfferComposer and ns.OfferComposer.remove then ns.OfferComposer.remove(current) end
    end)
    frame.remove:Hide()

    -- The claims on this offer, for the officer who posted it (Guild addon only). Each claim
    -- opens to what can be done with it: Award opens Send Mail with the reward and records the
    -- award when that mail goes; Decline records only; a decided claim can be requeued.
    local STATE = { [Reward.state.submitted] = "waiting", [Reward.state.settled] = "awarded",
        [Reward.state.declined] = "declined", [Reward.state.disputed] = "questioned" }
    local function say(ok, err) if not ok then GBA.Print("|cffff4040" .. tostring(err) .. "|r") end end
    frame.claimsMenu = CreateFrame("Frame", "GuildLedgerClaimsMenu", frame, "UIDropDownMenuTemplate")
    local function claimsMenu(_, level, menuList)
        local store = ns.officerClaims
        if not store or not current then return end
        if (level or 1) == 1 then
            local list = store:forReward(current.id)
            for _, r in ipairs(list) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = string.format("%s - %s%s", r.from, STATE[r.state] or "?",
                    r.repeated and " (already awarded before)" or "")
                info.hasArrow, info.notCheckable, info.menuList = true, true, r.id
                UIDropDownMenu_AddButton(info, 1)
            end
            if #list == 0 then
                local info = UIDropDownMenu_CreateInfo()
                info.text, info.disabled, info.notCheckable = "no claims yet", true, true
                UIDropDownMenu_AddButton(info, 1)
            end
            return
        end
        local r = store:get(menuList)
        if not r then return end
        local function item(text, fn)
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.notCheckable = text, true
            info.func = function() CloseDropDownMenus(); fn(); Detail.refresh() end
            UIDropDownMenu_AddButton(info, 2)
        end
        if r.state == Reward.state.submitted then
            item("Award (opens the reward mail)", function() say(ns.AwardFlow.begin(r.id)) end)
            item("Decline (return items yourself)", function() say(ns.AwardFlow.decline(r.id)) end)
        else
            item("Requeue: let " .. r.from .. " claim again", function() say(ns.requeueClaim(r.rewardID, r.from)) end)
        end
    end
    frame.claims = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.claims:SetScript("OnClick", function(self)
        UIDropDownMenu_Initialize(frame.claimsMenu, claimsMenu, "MENU")
        ToggleDropDownMenu(1, nil, frame.claimsMenu, self, 0, 0)
    end)
    frame.claims:Hide()

    anchorAll(frame)

    -- Held from build rather than only from show, so the wireframe can measure a detail
    -- view that has been built but never opened.
    Detail.frame = frame
    frame:Hide()
    return frame
end

-- Show ---------------------------------------------------------------------------

function Detail.show(frame, reward)
    current = reward
    Detail.frame = frame
    Detail.refresh()
end

-- Whether this character can change the offer: the Guild addon's composer is here, the role
-- list lets them publish, and they are the one who posted it.
local function canEdit(reward)
    return ns.OfferComposer ~= nil and ns.OfferComposer.edit ~= nil and ns.reviseReward ~= nil
        and GBA.mayAct("offer") and Reward.issuerMatches(reward.issuer, UnitName("player"))
end

function Detail.refresh()
    local frame, reward = Detail.frame, current
    if not frame or not reward then return end

    -- The offer may have changed while it was open: follow an edit, and leave a removed one.
    -- A guild quest in the log whose switch is gone is shown from the catalog, so it is not held.
    local catalog = ns.rewardCatalog
    if catalog then
        local live = catalog:live(reward.id)
        if not live and not reward.hardID then return ns.RewardsPanel.showList() end
        if live and live ~= reward then
            current, reward = live, live
            if ns.ClaimFlow and ns.ClaimFlow.select then ns.ClaimFlow.select(live) end
            ns.RewardsPanel.setTitle(live.title)
        end
    end
    frame.edit:SetShown(canEdit(reward))
    frame.remove:SetShown(canEdit(reward) and ns.OfferComposer.remove ~= nil)
    -- Its claims, for whoever may decide them: the poster, or a decider the poster named (DEC-4).
    local ownOffer = ns.decidable ~= nil and ns.decidable(reward.id) ~= nil
        and ns.officerClaims ~= nil and ns.AwardFlow ~= nil
    frame.claims:SetShown(ownOffer)
    if ownOffer then
        local open = 0
        for _, r in ipairs(ns.officerClaims:forReward(reward.id)) do
            if r.state == Reward.state.submitted then open = open + 1 end
        end
        frame.claims:SetText(open > 0 and ("Claims (" .. open .. ")") or "Claims")
    end

    -- Settled before anything is placed: anchorAll stacks the consent line under the picker
    -- when there is one and on the money row when there is not, so it has to know which.
    frame.sessions:SetShown(reward.attach == Reward.attach.session)

    -- The gold this claim would post, which rides on the mail rather than in a slot. Summed
    -- the same way ClaimFlow sums it, so the row cannot say one thing and the send do another.
    local copper = 0
    for _, want in ipairs(reward.wants or {}) do
        if want.kind == Reward.entryKind.money then copper = copper + (want.money or 0) end
    end
    frame.copperWanted = copper

    anchorAll(frame)

    -- The officer who built this had the items in their bags. This character may never
    -- have seen them, and an unknown item renders as its id, so ask for the names and
    -- redraw when they land.
    GBA.ItemCache.warm(GBA.ItemCache.idsIn(reward.wants), Detail.refresh)
    GBA.ItemCache.warm(GBA.ItemCache.idsIn(reward.gives), Detail.refresh)

    local names = Resolve.live(GBA.spokes)

    ns.Skin.setInput(frame.sender, tostring(reward.issuer))
    ns.Skin.setInput(frame.subject, reward.flavor or reward.title)

    -- The body comes from Core, not from here.
    --
    -- It used to be built in this function, and it moved because the officer's composer has
    -- to draw the same words on its last page - it promises to show an offer exactly as the
    -- player will see it, and that promise cannot survive two copies in two addons that
    -- install separately. Reward.bodyLines is the one copy, and it has tests, which this
    -- function never could.
    local actor = ns.actor and ns.actor() or {}
    local unlocked, unmet = Reward.gate(reward, actor)
    local lines, money = Reward.bodyLines(reward, Resolve, names, actor)

    local y = layoutLines(frame, lines)

    -- Gold, in the coin widget the whole default UI uses.
    if not frame.money then frame.money = ns.Skin.moneyFrame(frame.child) end
    if money > 0 then
        frame.money:ClearAllPoints()
        frame.money:SetPoint("TOPLEFT", frame.child, "TOPLEFT", 8, -y)
        frame.money:Set(money)
        y = y + 20
    else
        frame.money:Set(0)
    end

    y = y + layoutItems(frame, reward, y)
    frame.child:SetHeight(math.max(y + 6, 1))

    -- The letter just changed length, so the bar is told how far it now runs. This has to
    -- come after the child's height and not with the rest of the placement in anchorAll:
    -- a scroll range is read off the child, and at anchorAll time the child is still the
    -- size the last offer made it.
    if GBA.MailTabs.refreshScrollBar then GBA.MailTabs.refreshScrollBar(frame.scroll) end

    -- The slots, and the label above them. The label stays whatever happens: an offer
    -- asking for nothing still shows an empty row, and the row needs saying what it is.

    -- What this offer asks to be shared. Same list, same order, as the officer ticked.
    --
    -- No per-row "you share this / you do not" yet: the player's own sharing settings are a
    -- screen that does not exist. When it does, that status belongs on these rows, because
    -- an offer asking for something the player has not opted into must say so HERE rather
    -- than let them claim and send nothing.
    local asked = reward.data or {}
    frame.dataLabel:SetText(#asked > 0 and "This reward asks you to share:"
        or "This reward asks for no gameplay data.")

    for index, row in ipairs(frame.dataRows) do
        local key = asked[index]
        local category = key and Reward.dataCategory(key)
        row:SetText(category and ("- " .. category.label) or "")
        row:SetTextColor(0.85, 0.82, 0.72)
        row:SetShown(category ~= nil)
    end

    -- The consent panel, built from the claim that would actually be sent rather than
    -- written beside it, so the words cannot drift from the act.
    if (frame.copperWanted or 0) > 0 then frame.sendMoney:Set(frame.copperWanted) end

    local claim = ns.ClaimFlow.preview(reward)
    if claim then
        frame.consent:SetText(table.concat(Reward.describeClaim(claim, Resolve, names), "\n"))
    end

    -- Where each of these sits is anchorAll's business now, and whether the picker is shown
    -- was settled at the top of this function, before anything was placed.
    local needsSession = reward.attach == Reward.attach.session

    -- A reward that wants a session cannot be claimed until one is chosen: claiming would
    -- silently attach nothing and look like it worked.
    local chosen = ns.ClaimFlow.session()
    local ready = unlocked and (not needsSession or chosen ~= nil)

    frame.claim.locked = not ready
    frame.claim.unmet = unmet
    if not unlocked then
        frame.claim:SetText("Locked")
    elseif needsSession and not chosen then
        frame.claim:SetText("Pick a session")
    else
        frame.claim:SetText("Claim")
    end

    if ready then frame.claim:Enable() else frame.claim:Disable() end

    -- Already claimed: the claim's own status replaces the consent text, and Claim becomes
    -- Resend while any data or key letter is still on its way, or a spent "Claimed" once
    -- the officers have everything. One claim per offer from this character.
    frame.claim.mode = nil
    if ns.myClaims and ns.myClaims:blocks(reward.id) then
        frame.consent:SetText(table.concat(ns.claimLines(reward.id), "\n"))
        local resendable, why = ns.claimResendable(reward.id)
        frame.claim.locked, frame.claim.unmet = false, nil
        frame.claim.claimed = why
        if resendable then
            frame.claim.mode = "resend"
            frame.claim:SetText("Resend")
            frame.claim:Enable()
        else
            frame.claim.mode = "claimed"
            frame.claim:SetText("Claimed")
            frame.claim:Disable()
        end
    end

    -- A guild quest works like a real one: Accept, then Abandon while it is going, then Turn in
    -- at the mailbox it names - which is the claim above, unchanged. Spec Part 2.
    if reward.hardID and ns.hardState and not frame.claim.mode then
        local state, row = ns.hardState(reward.hardID)
        frame.claim.locked, frame.claim.unmet = false, nil
        if state == "offer" then
            frame.claim.mode = "accept"
            frame.claim:SetText("Accept")
            frame.claim.locked, frame.claim.unmet = not unlocked, unmet
            if unlocked then frame.claim:Enable() else frame.claim:Disable() end
        elseif state == "active" then
            frame.claim.mode = "abandon"
            frame.claim:SetText("Abandon")
            frame.claim:Enable()
            if row then frame.consent:SetText("In your guild quest log: " .. ns.describeProgress(row)) end
        elseif state == "turnIn" then
            frame.claim:SetText("Turn in")
            frame.claim:Enable()
        else
            frame.claim.mode = "claimed"
            frame.claim:SetText("Turned in")
            frame.claim:Disable()
        end
    end
end
