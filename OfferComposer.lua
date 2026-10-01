-- The Offers tab: composing an offer, in the frame it will be read in.
--
-- ONE panel, shaped like Send Mail, updated twice and posted on the third. Not three panels
-- taking turns - the officer stays in the same frame throughout and watches it fill:
--
--   stage 1  write it      To, Subject, the words, and what the player hands in
--   stage 2  reward it     the letter so far, locked, and now what they get back
--   stage 3  read it       the whole thing exactly as the player will see it, then Post!
--
-- Back steps one stage at a time; nothing is sent until Post! on stage 3.
--
-- Why the last page can be trusted. It draws through Reward.bodyLines, which is the same
-- function the player's claim view draws through - the one in Core, with tests. A preview
-- that rendered the offer with its own copy of that code would be telling the officer what
-- the code in THIS addon thinks the offer says, which is exactly the lie a preview exists to
-- prevent. One function, two callers, no drift.
--
-- Two things this frame deliberately does NOT do that the claim view does:
--
--   * It does not borrow SendMailAttachment1..12. The claim view borrows them because that
--     row genuinely is the outgoing mail's attachments. Here an officer is dragging items in
--     to DESCRIBE an offer, and putting those on the real attachment buttons would attach
--     real items out of their bags to a real mail. Our own buttons, anchored onto Blizzard's
--     positions: same place, nothing at stake.
--
--   * The To field is an audience, not an address list. Every offer still reaches the whole
--     guild's clients; members outside the audience do not list it, and an officer declines a
--     claim from outside it (Reward.inAudience). The level band is a level requirement:
--     outside it the offer shows, locked, with the reason.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end
if not GBA.MailTabs then return end

local Reward, Resolve = GBA.Reward, GBA.Resolve

local Composer = {}
ns.OfferComposer = Composer

local SLOT_SIZE = 37
local MAX_SLOTS = math.min(_G.ATTACHMENTS_MAX_SEND or 12, Reward.MAX_WANTS)

-- Measured off this client with /gba wireframe, for a mail frame that cannot be read.
local FALLBACK = {
    name    = { x = 90,  y = -30, w = 109, h = 25 },
    subject = { x = 90,  y = -55, w = 220, h = 20 },
    body    = { x = 8,   y = -82, w = 316, h = 198 },
    slot    = { x = 15,  y = -297 },
    money   = { x = 15,  y = -345 },
    send    = { x = 171, y = -398, w = 80, h = 22 },
    cancel  = { x = 251, y = -398, w = 80, h = 22 },
}

-- Who an offer is addressed to. Ranks, classes and players picked here are kept together, any
-- of them counts, and they travel on the offer as its audience.
--
-- Roster facts only - rank, class, level - and never a stored character name as the ADDRESS.
-- A name is a snapshot; rank and level and class are things the roster can re-answer. An
-- offer addressed to "rank Veteran or above" simply stops matching somebody who leaves the
-- guild, where one addressed to "Bob" leaves a dangling record on every synced account.
--
-- An individual is still reachable, through their class, because "this legendary is for
-- that person" is a real thing a guild wants. It is just the path you take deliberately
-- rather than the default, and there is no name box to type into.
--
-- Level is not one of these. It is a separate always-visible range that ANDs onto whatever
-- is chosen here, including "everyone" - which is why it cannot be a kind.
local KINDS = {
    { key = "everyone", label = "Everyone" },
    { key = "rank",     label = "By guild rank" },
    { key = "class",    label = "By class" },
}

-- The guild as the client currently knows it.
local function roster()
    local out = {}
    if type(GetNumGuildMembers) ~= "function" then return out end
    for index = 1, (GetNumGuildMembers() or 0) do
        local name, rankName, rankIndex, level, class, _, _, _, _, _, classFile =
            GetGuildRosterInfo(index)
        if name then
            out[#out + 1] = { name = name, rankName = rankName, rankIndex = rankIndex,
                              level = level, class = class, classFile = classFile }
        end
    end
    return out
end

local function inLevelBand(member, audience)
    local low, high = audience.levelMin, audience.levelMax
    if low and (member.level or 0) < low then return false end
    if high and (member.level or 0) > high then return false end
    return true
end

-- Distinct ranks, in the guild's own order.
local function ranksOf(list)
    local seen, out = {}, {}
    for _, member in ipairs(list) do
        if member.rankIndex and not seen[member.rankIndex] then
            seen[member.rankIndex] = true
            out[#out + 1] = { index = member.rankIndex, name = member.rankName }
        end
    end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
end

local function classesOf(list)
    local seen, out = {}, {}
    for _, member in ipairs(list) do
        if member.classFile and not seen[member.classFile] then
            seen[member.classFile] = true
            out[#out + 1] = { file = member.classFile, name = member.class }
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

-- Everyone of that class who is inside the level band. The band is what makes this list
-- usable: a guild's mages are forty names, and forty names in a dropdown is unpleasant.
local function playersOf(list, classFile, audience)
    local out = {}
    for _, member in ipairs(list) do
        if member.classFile == classFile and inLevelBand(member, audience) then
            out[#out + 1] = member.name
        end
    end
    table.sort(out)
    return out
end

local function rankName(index)
    for _, rank in ipairs(ranksOf(roster())) do
        if rank.index == index then return rank.name end
    end
    return "rank " .. tostring(index)
end

local function className(token)
    local names = _G.LOCALIZED_CLASS_NAMES_MALE
    return type(names) == "table" and names[token] or token
end

-- Everything picked, as words: ranks, then classes, then players. Picking was once one
-- "kind" at a time, and merely hovering the other submenu switched it, so the picks seemed to
-- vanish and every offer went to everyone. Now all three are kept together.
local function chosen(audience)
    local names = {}
    for _, index in ipairs(audience.ranks) do names[#names + 1] = rankName(index) end
    for _, token in ipairs(audience.classes) do names[#names + 1] = className(token) end
    for _, name in ipairs(audience.players) do names[#names + 1] = name end
    return names
end

-- Short enough for the To box, which is 109 units - about twenty characters. Words, not
-- "Rank(4,7)": a label that reads like code is a label somebody will eventually try to type.
local function summarise(audience)
    local picked = chosen(audience)
    local band = ""
    if audience.levelMin or audience.levelMax then band = " *" end

    if #picked == 0 then return "Everyone" .. band end
    if #picked == 1 then return picked[1] .. band end
    return string.format("%s and %d more%s", picked[1], #picked - 1, band)
end

-- The whole of it, for the tooltip and for stages 2 and 3, which have the room.
local function describeAudience(audience)
    local picked = chosen(audience)
    local who = #picked > 0 and table.concat(picked, ", ") or "Everyone in the guild"

    local low, high = audience.levelMin, audience.levelMax
    if low and high then return who .. ", level " .. low .. " to " .. high end
    if low then return who .. ", level " .. low .. " and above" end
    if high then return who .. ", level " .. high .. " and below" end
    return who
end

local STAGES = {
    [1] = { forward = "Queue",  back = "Clear", list = "wants" },
    [2] = { forward = "Review", back = "Back",  list = "gives" },
    [3] = { forward = "Post!",  back = "Back",  list = nil },
}

local panel, stage = nil, 1
local draft

local function blankDraft()
    return {
        -- Ranks by index, classes by token, players by name: any of them counts. Empty is
        -- everyone. The level band travels as a level requirement, not as audience.
        audience = { ranks = {}, classes = {}, players = {}, levelMin = nil, levelMax = nil },
        title = "", body = "",
        wants = {}, gives = {}, wantMoney = 0, giveMoney = 0, data = {}, icon = nil,
        readers = {},
        -- Who besides the poster may decide its claims (DEC-4). Every one of them is mailed each
        -- claim (DEC-5).
        deciders = {},
    }
end
draft = blankDraft()

-- The offer as a reward-shaped table, for the parts that read one.
--
-- Not Reward.new: that wants an issuer and a counter and would mint an id for something
-- which is not an offer yet. bodyLines reads four fields and this has all four.
--
-- Every entry goes through Reward.entry on the way in. A slot holds { itemID, quantity }
-- and nothing else, because that is all a drag knows; an entry the RENDERER can read also
-- carries its kind, and describeEntry switches on exactly that. Handing it the raw slot
-- table matched none of its branches and fell through to "?", so the last page - the one
-- that promises to show the offer as the player will see it - listed a row of question
-- marks for items it had every detail of. Posting went through Reward.new, which does this
-- same normalising, which is why what was posted was right and only the preview lied.
local function preview()
    local function entriesOf(list, money)
        local out = {}
        -- By slot number rather than with ipairs: these lists are keyed by which square the
        -- officer dropped into, so filling slots one and three leaves a hole at two, and
        -- ipairs stops dead at a hole. The post path already walks them this way.
        for index = 1, MAX_SLOTS do
            local entry = list[index] and Reward.entry(list[index])
            if entry then out[#out + 1] = entry end
        end
        if (money or 0) > 0 then
            out[#out + 1] = { kind = Reward.entryKind.money, money = money }
        end
        return out
    end

    local gives = entriesOf(draft.gives, draft.giveMoney)
    local wants = entriesOf(draft.wants, draft.wantMoney)

    return { body = draft.body, wants = wants, gives = gives, requires = {} }
end

-- Anchoring ----------------------------------------------------------------------

-- Onto the Send Mail frame it stands in for. Placed, not merely present: a Blizzard region
-- can carry art and still have no rectangle, and anchoring to one of those puts our widget
-- nowhere at all.
local function put(target, sourceName, fallback, dx, dy)
    local source = _G[sourceName]
    target:ClearAllPoints()
    if source and source.GetLeft and source:GetLeft() then
        target:SetPoint("TOPLEFT", source, "TOPLEFT", dx or 0, dy or 0)
        return source
    end
    target:SetPoint("TOPLEFT", panel, "TOPLEFT",
        (fallback.x or 0) + (dx or 0), (fallback.y or 0) + (dy or 0))
    return nil
end

-- Widgets ------------------------------------------------------------------------

local function label(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetTextColor(1, 0.82, 0.3)
    return fs
end

local function inputBox(parent, name)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

-- The letter's page, copied off Blizzard's stationery. Two halves, in the proportion the
-- source has them, because the right one is the torn edge of the page rather than half of it.
local function paper(parent)
    local sheet = CreateFrame("Frame", nil, parent)
    sheet:SetFrameLevel(math.max(0, (parent:GetFrameLevel() or 1) - 1))
    sheet.left = sheet:CreateTexture(nil, "BACKGROUND")
    sheet.right = sheet:CreateTexture(nil, "BACKGROUND")

    function sheet:dress()
        local left, right = _G.SendStationeryBackgroundLeft, _G.SendStationeryBackgroundRight
        local lw = (left and left.GetWidth and left:GetWidth()) or 252
        local rw = (right and right.GetWidth and right:GetWidth()) or 64
        local split = math.floor(self:GetWidth() * (lw / math.max(1, lw + rw)) + 0.5)

        self.left:SetPoint("TOPLEFT")
        self.left:SetPoint("BOTTOMRIGHT", self, "BOTTOMLEFT", split, 0)
        self.right:SetPoint("TOPLEFT", self, "TOPLEFT", split, 0)
        self.right:SetPoint("BOTTOMRIGHT")

        for target, source in pairs({ [self.left] = left, [self.right] = right }) do
            local texture = source and source.GetTexture and source:GetTexture()
            if texture then
                target:SetTexture(texture)
                if source.GetTexCoord then
                    local ok, a, b, c, d, e, f, g, h = pcall(source.GetTexCoord, source)
                    if ok and a then target:SetTexCoord(a, b, c, d, e, f, g, h) end
                end
                target:Show()
            else
                target:Hide()
            end
        end
    end

    return sheet
end

-- A slot the officer drags an item into. Ours, not Blizzard's - see the header.
local function makeSlot(parent, index)
    local slot = CreateFrame("Button", nil, parent)
    slot:SetSize(SLOT_SIZE, SLOT_SIZE)
    slot.index = index

    local bg = slot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.45)

    local border = slot:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.35, 0.35, 0.38, 0.9)

    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetAllPoints()
    slot.icon:Hide()

    slot.plus = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    slot.plus:SetPoint("CENTER")
    slot.plus:SetText("+")
    slot.plus:SetTextColor(0.4, 0.4, 0.45)

    slot.count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    slot.count:SetPoint("BOTTOMRIGHT", -2, 2)

    slot:SetScript("OnReceiveDrag", function(self) Composer.dropInto(self) end)
    slot:SetScript("OnClick", function(self)
        -- A cursor holding an item drops it; an empty cursor clears the slot. Two gestures,
        -- no modifier to remember.
        if not Composer.dropInto(self) then Composer.clearSlot(self) end
    end)
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    slot:EnableMouseWheel(true)
    slot:SetScript("OnMouseWheel", function(self, delta) Composer.nudge(self, delta) end)

    slot:SetScript("OnEnter", function(self)
        local held = Composer.held(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if held and held.itemID then
            if GameTooltip.SetItemByID then
                pcall(GameTooltip.SetItemByID, GameTooltip, held.itemID)
            end
            GameTooltip:AddLine(" ")
            local stack = GBA.Bags and GBA.Bags.maxStack(held.itemID)
            local full = stack and (held.quantity or 1) >= stack
            GameTooltip:AddLine("Asking for " .. (held.quantity or 1)
                .. (full and " - a full stack" or ""), 1, 1, 1)
            GameTooltip:AddLine(full
                and "One slot holds one stack. Use the next slot for more."
                or "Scroll to change how many; hold shift for ten.",
                0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("Click with an empty cursor to clear.", 0.7, 0.7, 0.7, true)
        else
            GameTooltip:AddLine("Empty slot", 1, 1, 1)
            GameTooltip:AddLine("Drag an item here from your bags. A whole stack drops as "
                .. "the whole stack; shift-drag to split part of one off first.",
                0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("Click with an empty cursor to clear.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return slot
end

-- Which list this stage's slots are editing.
local function activeList()
    local spec = STAGES[stage]
    return spec and spec.list and draft[spec.list] or nil
end

function Composer.held(slot)
    local list = activeList()
    return list and list[slot.index]
end

-- What one slot can be asked for: a stack, no more.
--
-- A slot IS an attachment, and an attachment holds one stack - twenty Linen Cloth, one
-- sword, two hundred arrows. Scrolling past that would write a number the mailbox cannot
-- carry in the slot it is written in, so the wheel stops there rather than counting on
-- forever. An item the client has not cached yet has no known stack size; that is a miss,
-- not a limit of one, so the reward's own ceiling stands in until the answer arrives.
local function ceilingFor(itemID)
    local stack = GBA.Bags and GBA.Bags.maxStack(itemID)
    return math.min(stack or Reward.MAX_QUANTITY, Reward.MAX_QUANTITY)
end

local function clampQuantity(value, itemID)
    value = math.floor(tonumber(value) or 1)
    if value < 1 then return 1 end
    local ceiling = ceilingFor(itemID)
    if value > ceiling then return ceiling end
    return value
end

function Composer.dropInto(slot)
    local list = activeList()
    if not list then return false end

    local kind, id = GetCursorInfo()
    -- Items only. The cursor hands back a spell BOOK SLOT for a spell rather than a spellID,
    -- so accepting one would store a number that means nothing.
    if kind ~= "item" or not id then return false end

    -- A dragged stack of twenty means twenty. The cursor will not say how many it is
    -- holding, so Bags watched the pick-up that put them there; when it has no answer the
    -- drop still lands, as one, and the wheel is there to correct it.
    local dropped = GBA.Bags and GBA.Bags.cursorStack()

    ClearCursor()
    list[slot.index] = { itemID = id, quantity = clampQuantity(dropped or 1, id) }
    Composer.render()
    return true
end

-- Changing how many, without a box to type in.
--
-- There is nowhere to put one: these slots sit on Blizzard's twelve attachment positions,
-- four pixels apart, and the row below them is the mail's money line. The wheel needs no
-- room at all, and holding shift moves it ten at a time so twenty linen is two turns rather
-- than twenty.
function Composer.nudge(slot, delta)
    local list = activeList()
    local held = list and list[slot.index]
    if not held or not held.itemID then return end

    local step = IsShiftKeyDown() and 10 or 1
    held.quantity = clampQuantity((held.quantity or 1) + delta * step, held.itemID)
    Composer.render()

    -- The tooltip is open - it is under the cursor - so it has to be redrawn or it goes on
    -- claiming the old number.
    if slot:IsMouseOver() and slot:GetScript("OnEnter") then
        slot:GetScript("OnEnter")(slot)
    end
end

function Composer.clearSlot(slot)
    local list = activeList()
    if not list then return end
    list[slot.index] = nil
    Composer.render()
end

-- Build --------------------------------------------------------------------------

local function build(host)
    panel = CreateFrame("Frame", "GuildLedgerOfferPanel", host)
    panel:SetSize(math.max(100, host:GetWidth() or 338), math.max(100, host:GetHeight() or 424))
    panel:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local titleSource = _G.SendMailTitleText or _G.MailFrameTitleText
    if titleSource then
        panel.title:SetPoint("CENTER", titleSource, "CENTER", 0, 0)
        if titleSource.GetFontObject and titleSource:GetFontObject() then
            panel.title:SetFontObject(titleSource:GetFontObject())
        end
    else
        panel.title:SetPoint("TOP", panel, "TOP", 0, -18)
    end

    panel.toLabel = label(panel, "To:")
    panel.to = CreateFrame("Frame", "GuildLedgerOfferAudience", panel, "UIDropDownMenuTemplate")
    -- Roughly the width of the To box it stands on, less the chrome a dropdown draws
    -- outside its own anchor.
    UIDropDownMenu_SetWidth(panel.to, 150)
    -- Multi-select needs no widget of ours: Blizzard's dropdown already does it.
    -- isNotRadio draws a checkbox instead of a radio dot, and keepShownOnClick leaves the
    -- menu open while you tick, which IS "click and highlight each one, then click out".
    local function toggle(list, value)
        for index, held in ipairs(list) do
            if held == value then table.remove(list, index) return end
        end
        list[#list + 1] = value
    end

    local function holds(list, value)
        for _, held in ipairs(list) do if held == value then return true end end
        return false
    end

    local function check(info, list, value)
        info.isNotRadio = true
        info.keepShownOnClick = true
        info.checked = holds(list, value)
        info.func = function()
            toggle(list, value)
            UIDropDownMenu_SetText(panel.to, summarise(draft.audience))
        end
        UIDropDownMenu_AddButton(info, UIDROPDOWNMENU_MENU_LEVEL)
    end

    UIDropDownMenu_Initialize(panel.to, function(self, level, menuList)
        local audience = draft.audience
        local list = roster()

        if level == 1 then
            for _, kind in ipairs(KINDS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = kind.label
                info.notCheckable = true
                info.hasArrow = kind.key ~= "everyone"
                info.menuList = kind.key
                if kind.key == "everyone" then
                    -- Choosing everyone is choosing nobody in particular, so the narrower
                    -- picks are dropped rather than kept and ignored.
                    info.func = function()
                        audience.ranks, audience.classes, audience.players = {}, {}, {}
                        CloseDropDownMenus()
                        Composer.render()
                    end
                end
                UIDropDownMenu_AddButton(info)
            end

        elseif level == 2 and menuList == "rank" then
            for _, rank in ipairs(ranksOf(list)) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = rank.name
                check(info, audience.ranks, rank.index)
            end

        elseif level == 2 and menuList == "class" then
            for _, class in ipairs(classesOf(list)) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = class.name
                -- Tick the class to take all of it, or open it to pick people out. Both
                -- are the same menu entry, which is what makes "down to a person" a
                -- continuation rather than a different mode.
                info.hasArrow = true
                info.menuList = class.file
                check(info, audience.classes, class.file)
            end

        elseif level == 3 then
            for _, name in ipairs(playersOf(list, menuList, audience)) do
                local short = name:match("^([^%-]+)") or name
                local info = UIDropDownMenu_CreateInfo()
                info.text = short
                check(info, audience.players, short)
            end
            if #playersOf(list, menuList, audience) == 0 then
                local info = UIDropDownMenu_CreateInfo()
                info.text = "nobody in that level range"
                info.notCheckable, info.disabled = true, true
                UIDropDownMenu_AddButton(info, UIDROPDOWNMENU_MENU_LEVEL)
            end
        end
    end)

    panel.to:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("This offer goes to", 1, 1, 1)
        GameTooltip:AddLine(describeAudience(draft.audience), 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Only they see it and can claim it. The level range locks it for anyone outside it.",
            0.6, 0.8, 0.6, true)
        GameTooltip:Show()
    end)
    panel.to:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- The level band, always on screen rather than hidden behind a menu choice.
    --
    -- It lives here because it ANDs onto everything, "everyone" included, so it was never a
    -- kind of audience - and because it is what makes the players-in-a-class list short
    -- enough to use. Two numeric boxes, in the 133 units Send Mail spends on postage and we
    -- do not. Blank is off, so there is no toggle to draw.
    local function levelBox(name, apply)
        local box = inputBox(panel, name)
        box:SetNumeric(true)
        box:SetSize(28, 18)
        box:SetMaxLetters(3)
        box:SetScript("OnTextChanged", function(self)
            apply(tonumber(self:GetText()))
            UIDropDownMenu_SetText(panel.to, summarise(draft.audience))
        end)
        return box
    end

    panel.levelLabel = label(panel, "Level")
    panel.levelMin = levelBox("GuildLedgerOfferLevelMin",
        function(value) draft.audience.levelMin = value end)
    panel.levelDash = label(panel, "-")
    panel.levelMax = levelBox("GuildLedgerOfferLevelMax",
        function(value) draft.audience.levelMax = value end)

    -- Stages 2 and 3 show the choice rather than offer it, so the dropdown gives way to a
    -- plain line of text.
    panel.toText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

    panel.subjectLabel = label(panel, "Subject:")
    panel.subject = inputBox(panel, "GuildLedgerOfferSubject")
    panel.subject:SetMaxLetters(Reward.MAX_TITLE)
    -- The button follows the subject as it is typed. It used to wait for something else to
    -- redraw the composer (picking from the To list did), so a written subject left it locked.
    panel.subject:SetScript("OnTextChanged", function(self)
        draft.title = self:GetText()
        Composer.refreshForward()
    end)

    panel.paper = paper(panel)

    -- Stage 1 writes into this; stages 2 and 3 hide it and show the rendered letter instead.
    panel.bodyScroll = CreateFrame("ScrollFrame", "GuildLedgerOfferBody", panel,
        "UIPanelScrollFrameTemplate")
    panel.bodyEdit = CreateFrame("EditBox", nil, panel.bodyScroll)
    panel.bodyEdit:SetMultiLine(true)
    -- The same ceiling Reward.new trims to. Cutting it here means the officer sees the
    -- limit while writing rather than discovering it after posting.
    panel.bodyEdit:SetMaxLetters(Reward.MAX_BODY or 0)
    panel.bodyEdit:SetAutoFocus(false)
    panel.bodyEdit:SetFontObject("QuestFont")
    panel.bodyEdit:SetTextColor(0.16, 0.12, 0.06)
    panel.bodyEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.bodyEdit:SetScript("OnTextChanged", function(self) draft.body = self:GetText() end)

    -- A HEIGHT, which it did not have and which is why the letter could not be written in.
    -- A multiline EditBox is zero units tall until it is told otherwise, and a box with no
    -- height has nothing to click, so it could never take focus - there was no way to type
    -- into it at all. It is deliberately taller than the page: the scroll frame is what
    -- decides how much of it shows, and a short box would stop accepting text at the fold.
    panel.bodyEdit:SetHeight(600)

    -- Keeps the cursor in view as it runs past the bottom of the page. Blizzard's own helper
    -- where the client has it - this is the same pair Send Mail's own body uses.
    if type(_G.ScrollingEdit_OnCursorChanged) == "function" then
        panel.bodyEdit:SetScript("OnCursorChanged", _G.ScrollingEdit_OnCursorChanged)
    end
    if type(_G.ScrollingEdit_OnUpdate) == "function" then
        panel.bodyEdit:SetScript("OnUpdate", function(self, elapsed)
            _G.ScrollingEdit_OnUpdate(self, elapsed, panel.bodyScroll)
        end)
    end

    panel.bodyScroll:SetScrollChild(panel.bodyEdit)

    -- Clicking the page puts the cursor in it, the way clicking a letter would. Without this
    -- only the text itself is a target, which on an empty letter is nothing.
    panel.bodyScroll:EnableMouse(true)
    panel.bodyScroll:SetScript("OnMouseDown", function()
        if stage == 1 then panel.bodyEdit:SetFocus() end
    end)

    -- The rendered letter gets a scroll frame of its own.
    --
    -- Stages 2 and 3 used to draw their lines straight onto the panel, anchored to the page.
    -- A page is 198 units tall and a body can be 400 characters, so a long offer simply ran
    -- off the bottom and over the buttons. Stage 1 always had a scroll frame because it is an
    -- edit box; the read-only stages needed the same and did not have it.
    panel.letterScroll = CreateFrame("ScrollFrame", "GuildLedgerOfferLetter", panel,
        "UIPanelScrollFrameTemplate")
    panel.letterChild = CreateFrame("Frame", nil, panel.letterScroll)
    panel.letterChild:SetSize(200, 100)
    panel.letterScroll:SetScrollChild(panel.letterChild)

    -- The rendered letter: one fontstring per line, from Reward.bodyLines, plus the coin
    -- widget and the icon row for what the offer gives back.
    panel.lines = {}
    panel.giveIcons = {}
    panel.giveCounts = {}

    -- The gold this offer gives back, written into the letter. A coin frame stood here and
    -- drew nothing on this client; see drawLetter for why this is words.
    panel.letterMoney = panel.letterChild:CreateFontString(nil, "OVERLAY",
        "QuestFontNormalSmall")
    panel.letterMoney:SetJustifyH("LEFT")
    panel.letterMoney:Hide()

    panel.slots = {}
    for index = 1, MAX_SLOTS do panel.slots[index] = makeSlot(panel, index) end

    -- Blizzard's own three-denomination purse, twice: one for the gold an offer ASKS for
    -- and one for the gold it gives back. Reward.entryKind.money already works in both
    -- lists and ClaimFlow already posts a requested amount - the composer simply had no way
    -- to say so, which is a gap rather than a new feature.
    local function purse(name, onChange)
        local frame
        local ok, built = pcall(CreateFrame, "Frame", name, panel, "MoneyInputFrameTemplate")
        if ok and built then frame = built end

        if frame and type(_G.MoneyInputFrame_SetOnValueChangedFunc) == "function" then
            _G.MoneyInputFrame_SetOnValueChangedFunc(frame, onChange)
            return frame
        end

        -- No template on this client: one gold-only box rather than nothing. Coarser, and
        -- it says so, instead of silently dropping the silver somebody typed.
        frame = inputBox(panel, name .. "Fallback")
        frame:SetNumeric(true)
        frame:SetSize(70, 18)
        frame.goldOnly = true
        frame:SetScript("OnTextChanged", function(self)
            self.copper = (tonumber(self:GetText()) or 0) * 10000
            onChange()
        end)
        return frame
    end

    local function copperOf(frame)
        if frame.goldOnly then return frame.copper or 0 end
        if type(_G.MoneyInputFrame_GetCopper) == "function" then
            local ok, value = pcall(_G.MoneyInputFrame_GetCopper, frame)
            if ok then return value or 0 end
        end
        return 0
    end
    Composer.copperOf = copperOf

    panel.moneyLabel = label(panel, "Gold to hand in:")
    panel.wantPurse = purse("GuildLedgerOfferWantGold", function()
        draft.wantMoney = copperOf(panel.wantPurse)
    end)
    panel.givePurse = purse("GuildLedgerOfferGiveGold", function()
        draft.giveMoney = copperOf(panel.givePurse)
    end)

    -- The data this offer asks for, in the strip the slot row gives up on the last page.
    --
    -- Flat, two columns, everything visible at once. This is the consent surface - the one
    -- list where a category tucked behind a collapsed node is a category nobody read - so it
    -- does not scroll and it does not hide. Core models the categories as a tree and this
    -- draws the leaves; the first one to grow children will draw as an expander, and only
    -- that one.
    --
    -- Editable HERE rather than earlier on purpose. Stage 3 is the draft, and this is the
    -- last thing decided before it goes: the letter above is what the player reads, and this
    -- is what they are agreeing to.
    panel.dataLabel = label(panel, "Ask the player to share:")
    panel.dataFoot = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.dataFoot:SetText("Nothing else is collected for this reward.")

    -- Only what something records: a box for a category with nothing behind it would ask the
    -- player to share data that never exists. Hover says what each one shares.
    panel.dataBoxes = {}
    local index = 0
    for _, category in ipairs(Reward.dataCategories) do
      if #(category.facts or {}) > 0 then
        index = index + 1
        local box = CreateFrame("CheckButton", "GuildLedgerOfferData" .. index, panel,
            "UICheckButtonTemplate")
        box:SetSize(20, 20)
        box.category = category

        box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
        box.label:SetText(category.label)

        box:SetScript("OnClick", function(self)
            local held = {}
            for _, key in ipairs(draft.data) do
                if key ~= self.category.key then held[#held + 1] = key end
            end
            if self:GetChecked() then held[#held + 1] = self.category.key end
            draft.data = Reward.dataRequest(held)
        end)
        box:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.category.label, 1, 1, 1)
            if self.category.tip then GameTooltip:AddLine(self.category.tip, 0.8, 0.8, 0.8, true) end
            GameTooltip:Show()
        end)
        box:SetScript("OnLeave", function() GameTooltip:Hide() end)

        panel.dataBoxes[index] = box
      end
    end

    -- Who else may read what this offer collects. The issuer always can; each name here gets
    -- a key letter of its own when a player claims. Only members the guild master's list (or,
    -- without one, rank) makes a reader are offered, because a claimant refuses the rest.
    -- On the last page these two share one line at the top of the letter, and the list under
    -- them (panel.officers) says in plain words what each name picked gets.
    panel.readersLabel = label(panel, "Readers:")
    panel.readers = CreateFrame("Frame", "GuildLedgerOfferReaders", panel, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(panel.readers, 74)

    local function readersText()
        local names = draft.readers or {}
        return #names == 0 and "none" or (#names == 1 and "1 name" or (#names .. " names"))
    end
    panel.readersText = readersText

    UIDropDownMenu_Initialize(panel.readers, function()
        local me = UnitName("player")
        local any = false
        for _, member in ipairs(roster()) do
            local short = member.name:match("^([^%-]+)") or member.name
            if short ~= me and GBA.Authority.may("reader", { name = short, rankIndex = member.rankIndex }) then
                any = true
                local info = UIDropDownMenu_CreateInfo()
                info.text = short
                info.isNotRadio = true
                info.keepShownOnClick = true
                info.checked = function()
                    for _, n in ipairs(draft.readers or {}) do if n == short then return true end end
                    return false
                end
                info.func = function()
                    local held, had = {}, false
                    for _, n in ipairs(draft.readers or {}) do
                        if n == short then had = true else held[#held + 1] = n end
                    end
                    if not had then held[#held + 1] = short end
                    draft.readers = Reward.readers(held) or {}
                    UIDropDownMenu_SetText(panel.readers, readersText())
                    Composer.render()
                end
                UIDropDownMenu_AddButton(info)
            end
        end
        if not any then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "no other readers in the guild"
            info.disabled = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)
        end
    end)

    -- Who else may decide the offer's claims (docs/fix-plan.md, DEC-4). Publishers only: deciding
    -- a claim is a publisher's job. A claim is mailed to every decider (DEC-5), so each one named
    -- costs the claiming player a letter's postage.
    panel.decidersLabel = label(panel, "Deciders:")
    panel.deciders = CreateFrame("Frame", "GuildLedgerOfferDeciders", panel, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(panel.deciders, 74)

    local function decidersText()
        local names = draft.deciders or {}
        return #names == 0 and "none" or (#names == 1 and "1 name" or (#names .. " names"))
    end
    panel.decidersText = decidersText

    -- Additional claim officers: whoever the two dropdowns name, each with what they get, in
    -- ink on the letter. Rebuilt by render.
    -- Part of the letter: it lives in the letter's scroll child, so the one borrowed bar scrolls
    -- it with everything else and the letter itself keeps its full size.
    panel.officersFrame = CreateFrame("Frame", nil, panel.letterChild)
    panel.officers = panel.officersFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.officers:SetJustifyH("LEFT")
    panel.officers:SetJustifyV("TOP")
    panel.officers:SetSpacing(2)
    panel.officers:SetTextColor(0.16, 0.12, 0.06)

    UIDropDownMenu_Initialize(panel.deciders, function()
        local me = UnitName("player")
        local any = false
        for _, member in ipairs(roster()) do
            local short = member.name:match("^([^%-]+)") or member.name
            if short ~= me and GBA.Authority.may("offer", { name = short, rankIndex = member.rankIndex }) then
                any = true
                local info = UIDropDownMenu_CreateInfo()
                info.text = short
                info.isNotRadio = true
                info.keepShownOnClick = true
                info.checked = function()
                    for _, n in ipairs(draft.deciders or {}) do if n == short then return true end end
                    return false
                end
                info.func = function()
                    local held, had = {}, false
                    for _, n in ipairs(draft.deciders or {}) do
                        if n == short then had = true else held[#held + 1] = n end
                    end
                    if not had then held[#held + 1] = short end
                    draft.deciders = Reward.readers(held) or {}
                    UIDropDownMenu_SetText(panel.deciders, decidersText())
                    Composer.render()
                end
                UIDropDownMenu_AddButton(info)
            end
        end
        if not any then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "no other publishers in the guild"
            info.disabled = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info)
        end
    end)

    -- The offer's icon, beside the opt-in list on the same last page.
    --
    -- An empty item slot, wearing Send Mail's own engraved square, so it reads as somewhere a
    -- thing goes rather than as a button. The list it is picked from is the client's own -
    -- see IconPicker - so nothing here maintains a table of texture paths.
    panel.iconSlot = CreateFrame("Button", "GuildLedgerOfferIcon", panel)
    panel.iconSlot:SetSize(36, 36)
    panel.iconSlot:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    panel.iconSlot.border = panel.iconSlot:CreateTexture(nil, "BACKGROUND", nil, -1)
    panel.iconSlot.border:SetPoint("TOPLEFT", -1, 1)
    panel.iconSlot.border:SetPoint("BOTTOMRIGHT", 1, -1)
    panel.iconSlot.border:SetColorTexture(0.35, 0.35, 0.38, 0.9)

    panel.iconLabel = label(panel, "Icon")

    panel.iconSlot:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            draft.icon = nil
            return Composer.render()
        end
        if not ns.IconPicker then return end
        ns.IconPicker.open(function(chosenIcon)
            draft.icon = chosenIcon
            Composer.render()
        end)
    end)

    panel.iconSlot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Offer icon", 1, 1, 1)
        GameTooltip:AddLine(draft.icon and "Right-click to clear."
            or "Click to choose one. Left empty, the offer borrows the icon of the first"
            .. " item it hands over.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    panel.iconSlot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    panel.forward = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.forward:SetScript("OnClick", function() Composer.forward() end)

    panel.back = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.back:SetScript("OnClick", function() Composer.back() end)

    Composer.render()
    return panel
end

-- Layout -------------------------------------------------------------------------

local function anchorAll()
    -- A dropdown draws about 16 units left of where it is anchored.
    put(panel.to, "SendMailNameEditBox", FALLBACK.name, -16, 2)
    UIDropDownMenu_SetWidth(panel.to, 100)

    -- Right of the To box: 199 to ~332, the 133 units real Send Mail spends on postage.
    panel.levelMax:ClearAllPoints()
    panel.levelMax:SetPoint("TOPLEFT", panel, "TOPLEFT", 296, -32)
    panel.levelDash:ClearAllPoints()
    panel.levelDash:SetPoint("RIGHT", panel.levelMax, "LEFT", -6, 0)
    panel.levelMin:ClearAllPoints()
    panel.levelMin:SetPoint("RIGHT", panel.levelDash, "LEFT", -6, 0)
    panel.levelLabel:ClearAllPoints()
    panel.levelLabel:SetPoint("RIGHT", panel.levelMin, "LEFT", -12, 0)
    panel.toText:ClearAllPoints()
    panel.toText:SetPoint("LEFT", panel.to, "LEFT", 22, 2)
    panel.toLabel:ClearAllPoints()
    panel.toLabel:SetPoint("RIGHT", panel.to, "LEFT", 10, 2)

    local subjectSource = put(panel.subject, "SendMailSubjectEditBox", FALLBACK.subject)
    if subjectSource then
        panel.subject:SetSize(subjectSource:GetWidth(), subjectSource:GetHeight())
    else
        panel.subject:SetSize(FALLBACK.subject.w, FALLBACK.subject.h)
    end
    panel.subjectLabel:ClearAllPoints()
    panel.subjectLabel:SetPoint("RIGHT", panel.subject, "LEFT", -6, 0)

    local left, right = _G.SendStationeryBackgroundLeft, _G.SendStationeryBackgroundRight
    local pw, ph = FALLBACK.body.w, FALLBACK.body.h
    if left and left.GetWidth and (left:GetWidth() or 0) > 1 then
        pw = math.floor(left:GetWidth() + ((right and right:GetWidth()) or 0) + 0.5)
        ph = math.floor(left:GetHeight() + 0.5)
    end
    put(panel.paper, "SendStationeryBackgroundLeft", FALLBACK.body)
    panel.paper:SetSize(pw, ph)
    panel.paper:dress()

    -- MailEditBox, the real writing area, rather than an inset guessed off the page.
    local BODY = { x = 28, y = -93, w = 268, h = 190 }
    local editBox = _G.MailEditBox
    local bodyW = (editBox and editBox.GetWidth and (editBox:GetWidth() or 0) > 1)
        and math.floor(editBox:GetWidth() + 0.5) or BODY.w
    local bodyH = (editBox and editBox.GetHeight and (editBox:GetHeight() or 0) > 1)
        and math.floor(editBox:GetHeight() + 0.5) or BODY.h

    for _, scroll in ipairs({ panel.bodyScroll, panel.letterScroll }) do
        put(scroll, "MailEditBox", BODY)
        scroll:SetSize(bodyW, bodyH)
    end
    -- The bar is not placed here any more. It is Blizzard's own, on loan, and it goes to
    -- whichever of the two bodies the current stage is showing - which render decides,
    -- after this function has run. See the loan at the end of Composer.render.

    panel.bodyEdit:SetWidth(bodyW - 6)
    panel.letterChild:SetWidth(bodyW - 6)

    panel.bodyEdit:SetWidth(pw - 40)
    panel.bodyEdit:SetHeight(math.max(600, ph))

    for index = 1, MAX_SLOTS do
        local column = (index - 1) % 7
        local row = math.floor((index - 1) / 7)
        put(panel.slots[index], "SendMailAttachment" .. index, {
            x = FALLBACK.slot.x + column * (SLOT_SIZE + 4),
            y = FALLBACK.slot.y - row * (SLOT_SIZE + 4),
        })
    end

    put(panel.moneyLabel, "SendMailMoneyText", FALLBACK.money, 0, -2)
    for _, frame in ipairs({ panel.wantPurse, panel.givePurse }) do
        frame:ClearAllPoints()
        frame:SetPoint("LEFT", panel.moneyLabel, "RIGHT", 12, 0)
    end

    -- Below the page, above the buttons. Two columns of four at 18 units a row uses about
    -- 72 of the 118 units between them.
    panel.dataLabel:ClearAllPoints()
    panel.dataLabel:SetPoint("TOPLEFT", panel.paper, "BOTTOMLEFT", 6, -6)

    -- Columns give up 46 units on the right so the icon slot has somewhere to be.
    local column = math.floor((panel.paper:GetWidth() - 58) / 2)
    panel.iconSlot:ClearAllPoints()
    panel.iconSlot:SetPoint("TOPRIGHT", panel.paper, "BOTTOMRIGHT", -6, -26)
    panel.iconLabel:ClearAllPoints()
    panel.iconLabel:SetPoint("BOTTOM", panel.iconSlot, "TOP", 0, 3)

    -- Two columns, as many rows as half the categories need.
    local rows = math.ceil(#panel.dataBoxes / 2)
    for index, box in ipairs(panel.dataBoxes) do
        local row = (index - 1) % rows
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", panel.dataLabel, "BOTTOMLEFT",
            (index > rows and column or 0), -2 - row * 18)
    end

    panel.dataFoot:ClearAllPoints()
    panel.dataFoot:SetPoint("TOPLEFT", panel.dataLabel, "BOTTOMLEFT", 2, -2 - rows * 18 - 4)

    -- Readers and Deciders are placed by render, at the top of the letter on the last page.

    for _, spec in ipairs({
        { button = panel.forward, source = "SendMailMailButton",   fallback = FALLBACK.send },
        { button = panel.back,    source = "SendMailCancelButton", fallback = FALLBACK.cancel },
    }) do
        local source = _G[spec.source]
        if source and source.GetWidth and (source:GetWidth() or 0) > 1 then
            spec.button:SetSize(source:GetWidth(), source:GetHeight())
        else
            spec.button:SetSize(spec.fallback.w, spec.fallback.h)
        end
        put(spec.button, spec.source, spec.fallback)
    end
end

-- Drawing the letter on stages 2 and 3, through Core's renderer.
local function drawLetter()
    local names = Resolve.live(GBA.spokes)
    local lines, money = Reward.bodyLines(preview(), Resolve, names)
    -- On the last page the letter opens with Readers, Deciders and the officer list.
    local y = (stage == 3) and Composer.layoutOfficers() or 0

    for index, entry in ipairs(lines) do
        local fs = panel.lines[index]
        if not fs then
            fs = panel.letterChild:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
            fs:SetJustifyH("LEFT")
            fs:SetSpacing(2)
            panel.lines[index] = fs
        end
        fs:SetWidth(panel.letterChild:GetWidth() - 6)
        fs:SetText(entry.text)
        fs:SetTextColor(entry.r or 0.16, entry.g or 0.12, entry.b or 0.06)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", panel.letterChild, "TOPLEFT", (entry.indent or 0), -y)
        fs:Show()
        y = y + fs:GetStringHeight() + (entry.gap or 3)
    end

    for index = #lines + 1, #panel.lines do panel.lines[index]:Hide() end

    -- Gold, then items. That is the order the claim view lays them out in, and the last page
    -- is only worth anything if it is in the same order as the page it is previewing.
    --
    -- In WORDS, and from bodyLines' own total rather than from the draft. The coin template
    -- drew nothing here: gold set on stage 2 posted correctly and showed on the offer
    -- afterwards, but the review page it was set on said nothing about it, which is the one
    -- page whose whole job is to say what is about to be sent. Words cannot fail to render,
    -- and they are the same words the line above them uses for the gold being asked FOR.
    if money > 0 then
        panel.letterMoney:ClearAllPoints()
        panel.letterMoney:SetPoint("TOPLEFT", panel.letterChild, "TOPLEFT", 10, -y)
        panel.letterMoney:SetText(Resolve.money(money))
        panel.letterMoney:SetTextColor(0.16, 0.12, 0.06)
        panel.letterMoney:Show()
        y = y + 20
    else
        panel.letterMoney:Hide()
    end

    -- The reward items, as icons inside the letter, because that is where the claim view
    -- draws them. bodyLines deliberately does not write them out as words - it returns
    -- hasItems and leaves the row to whoever is drawing. Leaving it undrawn here would make
    -- the last page a preview that is missing the thing the offer is FOR.
    local shown = 0
    local perRow = math.max(1, math.floor(panel.letterChild:GetWidth() / (SLOT_SIZE + 6)))

    -- By slot number, not with ipairs: a gap at slot two used to end the row there and
    -- quietly drop everything after it from the preview.
    for index = 1, MAX_SLOTS do
        local give = draft.gives[index]
        if give and give.itemID then
            shown = shown + 1
            local icon = panel.giveIcons[shown]
            if not icon then
                icon = panel.letterChild:CreateTexture(nil, "ARTWORK")
                icon:SetSize(SLOT_SIZE, SLOT_SIZE)
                panel.giveIcons[shown] = icon
            end
            local texture = type(GetItemInfo) == "function"
                and select(10, GetItemInfo(give.itemID))
            icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", panel.letterChild, "TOPLEFT",
                ((shown - 1) % perRow) * (SLOT_SIZE + 6),
                -y - math.floor((shown - 1) / perRow) * (SLOT_SIZE + 6))
            icon:Show()

            -- How many, on the icon, the way every item square in the game says it. An
            -- icon on its own reads as one of something, so a reward of five was being
            -- under-reported by four on the page whose job is to report it.
            local count = panel.giveCounts[shown]
            if not count then
                count = panel.letterChild:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
                panel.giveCounts[shown] = count
            end
            count:ClearAllPoints()
            count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -2, 2)
            count:SetText((give.quantity or 1) > 1 and give.quantity or "")
            count:Show()
        end
    end

    for index = shown + 1, #panel.giveIcons do panel.giveIcons[index]:Hide() end
    for index = shown + 1, #panel.giveCounts do panel.giveCounts[index]:Hide() end

    if shown > 0 then
        y = y + math.ceil(shown / perRow) * (SLOT_SIZE + 6)
    end
    panel.letterChild:SetHeight(math.max(y + 6, 1))
end

-- The last page's top of the letter: Readers and Deciders on one line, and under them the
-- additional claim officers in plain words. All of it inside the letter's scroll child, so the
-- letter keeps its size and its bar, and scrolling moves the whole body. Returns its height.
function Composer.layoutOfficers()
    local child = panel.letterChild
    local width = child:GetWidth() or 260
    local level = (child:GetFrameLevel() or 1) + 1
    for _, frame in ipairs({ panel.officersFrame, panel.readers, panel.deciders }) do
        if frame:GetParent() ~= child then frame:SetParent(child) end
        frame:SetFrameLevel(level)
    end
    for _, l in ipairs({ panel.readersLabel, panel.decidersLabel }) do
        if l:GetParent() ~= panel.officersFrame then l:SetParent(panel.officersFrame) end
        l:SetTextColor(0.35, 0.2, 0.05)   -- ink: these sit on the paper
    end

    panel.officersFrame:ClearAllPoints()
    panel.officersFrame:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
    panel.officersFrame:SetWidth(width)

    panel.readersLabel:ClearAllPoints()
    panel.readersLabel:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -6)
    panel.readers:ClearAllPoints()
    panel.readers:SetPoint("LEFT", panel.readersLabel, "RIGHT", -14, -2)
    panel.decidersLabel:ClearAllPoints()
    panel.decidersLabel:SetPoint("LEFT", panel.readers, "RIGHT", -8, 2)
    panel.deciders:ClearAllPoints()
    panel.deciders:SetPoint("LEFT", panel.decidersLabel, "RIGHT", -14, -2)

    -- Who gets what. A name in both lists is one line.
    local order, can = {}, {}
    local function add(list, what)
        for _, name in ipairs(list or {}) do
            if not can[name] then can[name] = {}; order[#order + 1] = name end
            can[name][what] = true
        end
    end
    add(draft.readers, "read")
    add(draft.deciders, "decide")
    local lines = { "|cff5a3a10Additional claim officers|r" }
    if #order == 0 then
        lines[#lines + 1] = "None: only you see what players share, and only you award their claims."
    end
    for _, name in ipairs(order) do
        local c = can[name]
        if c.read and c.decide then
            lines[#lines + 1] = name .. " gets each claim by mail, can award it, and can read what the player shares."
        elseif c.decide then
            lines[#lines + 1] = name .. " gets each claim by mail and can award or decline it."
        else
            lines[#lines + 1] = name .. " can read what the player shares."
        end
    end
    panel.officers:ClearAllPoints()
    panel.officers:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -32)
    panel.officers:SetWidth(width - 6)
    panel.officers:SetText(table.concat(lines, "\n"))

    local used = 32 + math.ceil(panel.officers:GetStringHeight() or 24) + 10
    panel.officersFrame:SetHeight(used)
    return used
end

-- Render -------------------------------------------------------------------------

function Composer.render()
    if not panel then return end
    anchorAll()

    local spec = STAGES[stage] or STAGES[1]
    local writing = stage == 1

    -- Editing a posted offer says so in the title (Remove lives beside Edit on the open offer).
    if draft.editing then
        panel.title:SetText(({ "Editing offer", "Editing its reward", "Ready to update" })[stage] or "Editing offer")
    else
        panel.title:SetText(({ "New offer", "Its reward", "Ready to post" })[stage] or "New offer")
    end

    panel.to:SetShown(writing)
    panel.toText:SetShown(not writing)
    for _, part in ipairs({ panel.levelLabel, panel.levelMin, panel.levelDash, panel.levelMax }) do
        part:SetShown(writing)
    end

    UIDropDownMenu_SetText(panel.to, summarise(draft.audience))
    -- Stages 2 and 3 have the full width, so they spell it out rather than collapsing it.
    panel.toText:SetText(describeAudience(draft.audience))

    panel.subject:SetShown(true)
    panel.subject:EnableMouse(writing)
    panel.subject:EnableKeyboard(writing)
    if panel.subject:GetText() ~= draft.title then panel.subject:SetText(draft.title or "") end

    -- Stage 1 is the only one with a cursor in the letter. After that it is a letter, not
    -- a form, and it is drawn the way the player will be shown it.
    panel.bodyScroll:SetShown(writing)
    panel.letterScroll:SetShown(not writing)
    if writing then
        if panel.bodyEdit:GetText() ~= draft.body then
            panel.bodyEdit:SetText(draft.body or "")
        end
        for _, fs in ipairs(panel.lines) do fs:Hide() end
        for _, icon in ipairs(panel.giveIcons) do icon:Hide() end
        for _, count in ipairs(panel.giveCounts) do count:Hide() end
        panel.letterMoney:Hide()
    else
        drawLetter()
    end

    -- The bar follows whichever body is up.
    --
    -- There is exactly one scroll bar to be had - it is the mail frame's, on loan - and the
    -- composer has two bodies: the editor on stage 1 and the rendered letter on stages 2
    -- and 3. Only one is ever shown, so the loan simply moves with the stage, and the one
    -- that is not shown falls back to nothing, which is right, because nothing is looking
    -- at it.
    --
    -- Lent here rather than in anchorAll because a scroll range is read off the child, and
    -- drawLetter has only just finished setting the letter's height.
    local body = writing and panel.bodyScroll or panel.letterScroll
    local lent, why = GBA.MailTabs.lendScrollBar(body)
    if not lent then
        -- No mail bar on this client: each frame keeps the one its template built, parked
        -- where the real one would have been. This is the old path, kept as the fallback.
        for _, name in ipairs({ "GuildLedgerOfferBody", "GuildLedgerOfferLetter" }) do
            local bar = _G[name .. "ScrollBar"]
            if bar then
                if GBA.MailTabs.dressScrollBar then GBA.MailTabs.dressScrollBar(bar) end
                put(bar, "MailEditBoxScrollBar", { x = 307, y = -99 }, 4, -20)
            end
        end
        if not panel.barWarned then
            panel.barWarned = true
            GBA.Print("|cffffcc00" .. tostring(why) .. "; using our own|r")
        end
    end

    local list = spec.list and draft[spec.list]
    for index = 1, MAX_SLOTS do
        local slot = panel.slots[index]
        local held = list and list[index]
        -- Gone entirely on the last page. Everything the offer asks for and everything it
        -- gives is in the letter by then, so a row of item squares underneath is the same
        -- facts twice - and that strip is wanted for the data this offer requests.
        slot:SetShown(stage < 3 and (index <= 7 or (list and list[index] ~= nil)))

        -- On the last page the slots show what the PLAYER hands in, because that is what
        -- their claim view will show in the same row.
        local shown = (stage == 3) and draft.wants[index] or held
        if shown and shown.itemID then
            local texture = type(GetItemInfo) == "function" and select(10, GetItemInfo(shown.itemID))
            slot.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            slot.icon:Show()
            slot.plus:Hide()
            slot.count:SetText((shown.quantity or 1) > 1 and shown.quantity or "")
        else
            slot.icon:Hide()
            slot.plus:SetShown(stage < 3)
            slot.count:SetText("")
        end
        slot:EnableMouse(spec.list ~= nil)
    end

    -- One purse per side, each on the stage that sets it. Stage 3 sets neither: by then both
    -- amounts are in the letter, where the player reads them.
    panel.wantPurse:SetShown(stage == 1)
    panel.givePurse:SetShown(stage == 2)
    panel.moneyLabel:SetShown(stage < 3)
    panel.moneyLabel:SetText(stage == 1 and "Gold to hand in:"
        or (_G.AMOUNT_TO_SEND or "Amount to send:"))

    local asking = stage == 3
    panel.dataLabel:SetShown(asking)
    panel.dataFoot:SetShown(asking)
    panel.readersLabel:SetShown(asking)
    panel.readers:SetShown(asking)
    UIDropDownMenu_SetText(panel.readers, panel.readersText())
    panel.decidersLabel:SetShown(asking)
    panel.deciders:SetShown(asking)
    UIDropDownMenu_SetText(panel.deciders, panel.decidersText())
    panel.officersFrame:SetShown(asking)
    panel.iconSlot:SetShown(asking)
    panel.iconLabel:SetShown(asking)

    -- The chosen icon BECOMES the slot's normal texture, replacing the engraved square,
    -- rather than being drawn as a layer on top of it. Two reasons, both learned already:
    -- Skin.setSlot found that an icon layered over slot art gets clipped to a sliver,
    -- because both sit in the same draw layer and the slot wins - and clearing a normal
    -- texture by passing nil is rejected outright on this client
    -- ("bad argument #2 to SetNormalTexture"), which is what this line used to do.
    if draft.icon then
        pcall(panel.iconSlot.SetNormalTexture, panel.iconSlot, draft.icon)
    elseif ns.IconPicker then
        ns.IconPicker.slotArt(panel.iconSlot)
    end

    for _, box in ipairs(panel.dataBoxes) do
        box:SetShown(asking)
        local held = false
        for _, key in ipairs(draft.data) do
            if key == box.category.key then held = true break end
        end
        box:SetChecked(held)
    end

    panel.forward:SetText(spec.forward)
    panel.back:SetText(spec.back)

    -- Editing an offer already out: Post! updates it and Clear gives up the edit. Remove is on
    -- the open offer, beside Edit, well away from the way to Post!.
    local editing = draft.editing ~= nil
    if editing and stage == 3 then panel.forward:SetText("Update") end
    if editing and stage == 1 then panel.back:SetText("Cancel") end

    Composer.refreshForward()
end

-- Stage 1 moves on once there is a subject. The To list always has an answer (nobody picked is
-- everyone), and the body may stay blank.
function Composer.refreshForward()
    if not panel or not panel.forward then return end
    local ready = (draft.title or ""):find("%S") ~= nil
    if stage == 1 and not ready then panel.forward:Disable() else panel.forward:Enable() end
end

-- Moving between stages -----------------------------------------------------------

function Composer.forward()
    if stage < 3 then
        stage = stage + 1
        return Composer.render()
    end
    Composer.post()
end

function Composer.back()
    if stage > 1 then
        stage = stage - 1
        return Composer.render()
    end
    -- Stage 1's back button is Clear, because there is nothing behind stage 1.
    draft = blankDraft()
    panel.bodyEdit:SetText("")
    panel.subject:SetText("")
    panel.levelMin:SetText("")
    panel.levelMax:SetText("")
    Composer.render()
end

local function entriesFrom(list, extra)
    local out = {}
    for index = 1, MAX_SLOTS do
        if list[index] then out[#out + 1] = list[index] end
    end
    -- Entries the slots cannot show (words, spells) from an offer being edited, carried
    -- through unchanged rather than lost.
    for _, entry in ipairs(extra or {}) do out[#out + 1] = entry end
    return out
end

local function resetFields()
    panel.bodyEdit:SetText(draft.body or "")
    panel.subject:SetText(draft.title or "")
    -- The draft's own band, not blank: blanking fires the boxes' change handler, which would
    -- clear the band an edit has just loaded.
    local low, high = draft.audience.levelMin, draft.audience.levelMax
    panel.levelMin:SetText(low and tostring(low) or "")
    panel.levelMax:SetText(high and tostring(high) or "")
end

-- Opens a posted offer in the composer to change it: every field filled from the offer, on
-- the first page, with Remove at the top. The Rewards tab's Edit button calls this.
-- Remove, from the open offer beside Edit. Asks first: a removal reaches every member and cannot
-- be taken back.
function Composer.remove(reward)
    if not reward or not reward.id then return end
    StaticPopup_Show("GUILDLEDGER_REMOVE_OFFER", reward.title or "", nil, reward.id)
end

function Composer.edit(reward)
    if type(reward) ~= "table" or not reward.id then return end
    draft = blankDraft()
    draft.editing = reward.id
    draft.title, draft.body, draft.icon = reward.title or "", reward.body or "", reward.icon
    draft.data = Reward.dataRequest(reward.data or {})
    local audience = reward.audience or {}
    for _, key in ipairs({ "ranks", "classes", "players" }) do
        for _, v in ipairs(audience[key] or {}) do draft.audience[key][#draft.audience[key] + 1] = v end
    end
    for _, req in ipairs(reward.requires or {}) do
        if req.kind == Reward.requireKind.level then
            draft.audience.levelMin, draft.audience.levelMax = req.min, req.max
        end
    end
    for _, name in ipairs(reward.readers or {}) do draft.readers[#draft.readers + 1] = name end
    for _, name in ipairs(reward.deciders or {}) do draft.deciders[#draft.deciders + 1] = name end

    -- Items into slots, gold into the money line, and anything else carried as it is.
    local function unpack(entries, slots)
        local money, extra, index = 0, {}, 0
        for _, entry in ipairs(entries or {}) do
            if entry.kind == Reward.entryKind.money then
                money = money + (entry.money or 0)
            elseif entry.itemID and index < MAX_SLOTS then
                index = index + 1
                slots[index] = { itemID = entry.itemID, quantity = entry.quantity or 1 }
            else
                extra[#extra + 1] = entry
            end
        end
        return money, extra
    end
    draft.wantMoney, draft.wantsExtra = unpack(reward.wants, draft.wants)
    draft.giveMoney, draft.givesExtra = unpack(reward.gives, draft.gives)

    stage = 1
    if ns.offersTab then ns.offersTab.select() end
    if panel then
        resetFields()
        Composer.render()
    end
end

StaticPopupDialogs["GUILDLEDGER_REMOVE_OFFER"] = {
    text = "Remove the offer \"%s\"?\n\nIt disappears for every member, including anyone offline now, the next time they refresh. It cannot be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    -- data: the offer's id, from Composer.remove (the open offer's Remove button).
    OnAccept = function(_, id)
        id = id or draft.editing
        if not id or not ns.retractReward then return end
        local removed, err = ns.retractReward(id)
        if not removed then return GBA.Print("|cffff4040" .. tostring(err) .. "|r") end
        -- A composer holding an edit of this offer lets it go.
        if draft.editing == id and panel then
            draft = blankDraft()
            stage = 1
            resetFields()
            Composer.render()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Composer.post()
    if not ns.publishReward then
        return GBA.Print("|cffff4040the offer module is not loaded|r")
    end

    local gives = entriesFrom(draft.gives, draft.givesExtra)
    if (draft.giveMoney or 0) > 0 then gives[#gives + 1] = { money = draft.giveMoney } end

    local wants = entriesFrom(draft.wants, draft.wantsExtra)
    if (draft.wantMoney or 0) > 0 then wants[#wants + 1] = { money = draft.wantMoney } end

    -- Editing sends the next revision of the same offer; otherwise it is a new one.
    local editing = draft.editing
    local send = editing and function(fields) return ns.reviseReward(editing, fields) end
        or ns.publishReward

    local reward, err = send({
        title = draft.title,
        body = draft.body,
        wants = wants,
        data = draft.data,
        readers = draft.readers,
        deciders = draft.deciders,
        audience = { ranks = draft.audience.ranks, classes = draft.audience.classes,
            players = draft.audience.players },
        -- The level band, as the level requirement Reward.gate already enforces: players
        -- outside it see the offer, locked, with the reason.
        requires = (draft.audience.levelMin or draft.audience.levelMax) and {
            { kind = Reward.requireKind.level, min = draft.audience.levelMin, max = draft.audience.levelMax },
        } or nil,
        icon = draft.icon,
        gives = gives,
        -- Ticking a data category is asking for data: without this the offer went out
        -- asking for nothing, and claims carried no data and no key letter.
        attach = (#Reward.dataRequest(draft.data) > 0) and Reward.attach.all or Reward.attach.none,
    })
    if not reward then
        return GBA.Print("|cffff4040" .. tostring(err) .. "|r")
    end

    -- An edit was already announced by reviseReward.
    if not editing then
        GBA.Print(string.format("posted |cff00d1ff%s|r to %s", reward.title, describeAudience(draft.audience)))
    end

    draft = blankDraft()
    stage = 1
    panel.bodyEdit:SetText("")
    panel.subject:SetText("")
    Composer.render()
end

ns.offersTab = GBA.MailTabs.register({
    key = "offers",
    -- The composer IS Send Mail, so it wears Send Mail - which means the page the
    -- letter is written on is Blizzard's real stationery rather than a copy of it.
    wears = "sendmail",
    label = "Offers",
    build = build,
    onShow = function()
        -- Asked for, not assumed. GetGuildRosterInfo answers from a cache the client only
        -- fills after a request, so an officer who has not opened the guild pane this
        -- session would otherwise find every submenu empty.
        if type(GuildRoster) == "function" then pcall(GuildRoster) end
        Composer.render()
    end,
})

local frame = CreateFrame("Frame")
frame:RegisterEvent("MAIL_SHOW")
frame:SetScript("OnEvent", function()
    if GBA.MailTabs.attach() and ns.offerCatalog then
        ns.offersTab.setCount(ns.offerCatalog:count())
    end
end)
