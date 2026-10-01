-- Borrowed chrome: the fonts, backgrounds and button templates the reward tab is made of.
--
-- Every one of these is Blizzard's, and every one of them is asked for by name at runtime
-- rather than assumed to exist. The design document names templates from 3.3.5 FrameXML;
-- this client is Classic Era, which is the modern engine wearing vanilla's art, and the
-- two do not agree everywhere. Rather than guess which half is right, each thing is tried
-- in order of preference and the first that actually builds wins - the same construction
-- Core's MailTabs already uses for its tab button, for the same reason.
--
-- What is NOT borrowed is behaviour. QuestInfoRewardItemTemplate looks like exactly the
-- button we want, but the scripts it carries are quest scripts: they call
-- GameTooltip:SetQuestItem and read fields that only exist while a quest is open, so
-- inheriting them outside a quest is an error waiting for the first mouseover. The
-- template is taken for its LOOK, and every script on the result is then replaced with
-- ours. /gba uiprobe prints what this client actually handed back.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Skin = {}
ns.Skin = Skin

-- What was actually used, for the probe to report.
Skin.using = {}

-- Fonts ----------------------------------------------------------------------

-- Returns the first of these font objects the client has, as a name a FontString can
-- inherit. The last one is the fallback and is always a font every client has.
local function firstFont(...)
    local names = { ... }
    for i = 1, #names do
        if _G[names[i]] then return names[i] end
    end
    return names[#names]
end

Skin.fonts = {}

function Skin.load()
    if Skin.loaded then return end
    Skin.loaded = true

    -- The quest fonts, with the general-purpose ones behind them. A parchment panel set
    -- in the default gold-on-grey font is what "looks bolted on" means.
    Skin.fonts.title = firstFont("QuestTitleFont", "GameFontNormalLarge")
    Skin.fonts.body = firstFont("QuestFont", "GameFontHighlight")
    Skin.fonts.objective = firstFont("QuestFontNormalSmall", "GameFontHighlightSmall")
    Skin.fonts.header = firstFont("QuestFontNormalHuge", "QuestTitleFont", "GameFontNormalLarge")

    Skin.using.fonts = Skin.fonts
end

-- Parchment ------------------------------------------------------------------

-- The paper is copied off the client, never named.
--
-- Guessing a texture path put a black panel on screen twice: a file this client does not
-- have draws nothing at all, silently, and no addon on this machine references a parchment
-- path, so there was nothing to check a guess against.
--
-- Reading one off the client took two goes as well, and the reason is worth keeping. A
-- probe reported every region of MailFrame - including its own background and portrait,
-- both plainly on screen - as having no texture. They do have one. Classic Era runs the
-- modern engine, where:
--
--   * a texture set from an atlas returns nil from GetTexture() and has to be asked for
--     with GetAtlas(), and
--   * a texture set by file ID returns a NUMBER, not a path.
--
-- Requiring a string threw away both. Everything here therefore copies whatever a region
-- turns out to be - atlas, file ID or path - rather than looking at what it is called.
--
-- Three sources, best first:
--
--   1. The quest material. Blizzard papers its quest panels with four corner textures
--      named off the panel that owns them, and this client has exactly those. Copied as
--      four quadrants, that IS the quest parchment.
--   2. The stationery halves, which are the body of a letter and nothing else - no border,
--      no chrome.
--   3. Any background region on the mail or quest frames, chosen by what the REGION is
--      called, since a file ID has no name to match on.
--
-- All of it is retried whenever the client draws one of those frames, because the textures
-- are filled in lazily and an unopened quest frame really does have empty corners.

local MATERIAL_OWNERS = {
    "QuestFrameDetailPanel", "QuestFrameRewardPanel", "QuestFrameProgressPanel",
    "QuestFrameGreetingPanel", "QuestInfoFrame", "QuestLogDetailFrame",
}
local MATERIAL_CORNERS = { "MaterialTopLeft", "MaterialTopRight", "MaterialBotLeft", "MaterialBotRight" }

-- Left half, right half. Blizzard sets both at once, so a pair is taken or neither is.
local STATIONERY_PAIRS = {
    { "SendStationeryBackgroundLeft", "SendStationeryBackgroundRight" },
    { "OpenStationeryBackgroundLeft", "OpenStationeryBackgroundRight" },
}

local PARCHMENT_SOURCES = {
    "InboxFrame", "SendMailFrame", "OpenMailFrame", "MailFrame",
    "QuestInfoFrame", "QuestFrameDetailPanel", "QuestFrameRewardPanel",
    "QuestFrameProgressPanel", "QuestFrameGreetingPanel", "QuestFrame",
}

-- Matched against the REGION's name, not the texture's: a file ID has no name of its own.
local STRONG_NAMES = { "material", "parchment", "stationery", "bg$", "background" }
local NOT_PAPER = { "border", "button", "tab", "highlight", "icon", "corner",
                    "shadow", "portrait", "title", "streak", "coin", "bar" }

local function matches(text, patterns)
    for _, pattern in ipairs(patterns) do
        if text:find(pattern) then return true end
    end
    return false
end

-- What a region is actually showing. Returns "atlas", name or "file", pathOrID, or nil.
local function textureOf(region)
    if not region or not region.GetObjectType then return nil end
    local ok, kind = pcall(region.GetObjectType, region)
    if not ok or kind ~= "Texture" then return nil end

    -- Atlas first: a texture set from one answers nil to GetTexture, which is what made
    -- every region on the mail frame look empty.
    if region.GetAtlas then
        local got, atlas = pcall(region.GetAtlas, region)
        if got and type(atlas) == "string" and atlas ~= "" then return "atlas", atlas end
    end

    local got, file = pcall(region.GetTexture, region)
    if got and ((type(file) == "string" and file ~= "") or type(file) == "number") then
        return "file", file
    end
    return nil
end

-- For printing. A file ID is a number and has no path to show.
local function describeTexture(region)
    local kind, value = textureOf(region)
    if not kind then return nil end
    if kind == "atlas" then return "atlas:" .. value end
    if type(value) == "number" then return "fileID:" .. value end
    return value
end
Skin.describeTexture = describeTexture

-- Copies a region whole: whatever it is showing, and the corner of it being shown.
local function copyTexture(target, source)
    local kind, value = textureOf(source)
    if not kind then return false end

    if kind == "atlas" then
        -- An atlas carries its own coordinates; setting them afterwards would undo it.
        local ok = pcall(target.SetAtlas, target, value, true)
        if not ok then return false end
        return true
    end

    target:SetTexture(value)
    if source.GetTexCoord and target.SetTexCoord then
        local got, ulx, uly, llx, lly, urx, ury, lrx, lry = pcall(source.GetTexCoord, source)
        if got and ulx then
            target:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
        end
    end
    return true
end

-- Blizzard fills these in when it updates a frame, and not before. Calling its own updater
-- is quieter than flipping the player through the Send Mail tab to make it happen, and
-- every one is optional.
local PRIMERS = { "SendMailFrame_Update", "OpenMail_Update", "InboxFrame_Update" }

local function prime()
    if Skin.primed then return end
    Skin.primed = true
    for _, name in ipairs(PRIMERS) do
        if type(_G[name]) == "function" then pcall(_G[name]) end
    end
end

-- The four corners of a papered quest panel, or nil.
function Skin.material()
    for _, owner in ipairs(MATERIAL_OWNERS) do
        local corners, found = {}, 0
        for index, corner in ipairs(MATERIAL_CORNERS) do
            local region = _G[owner .. corner]
            if textureOf(region) then
                corners[index] = region
                found = found + 1
            end
        end
        -- All four, or it is not a sheet. A single lit corner is a frame mid-update.
        if found == #MATERIAL_CORNERS then return corners, owner end
    end
    return nil
end

local function area(region)
    local ok, width, height = pcall(function() return region:GetWidth(), region:GetHeight() end)
    if not ok or not width or not height then return 0 end
    return width * height
end

-- The inbox's paper. A single sheet, and a different one from the letter body: the inbox
-- fills its whole inset, where the stationery is the page a letter is written on and has a
-- torn right edge. The list wants the first; the claim view wants the second.
local INBOX_REGIONS = { "InboxFrameBg" }

-- Strictly the inbox's own regions.
--
-- MailFrame was in this list once and it should never have been: MailFrameBg is the dark
-- stone the whole window is cut from, its name ends in "bg", and it is the largest thing
-- in sight - so a scan that reached that far chose the frame's backing over the paper and
-- the list came out looking like a hole. Better to find nothing and fall through to the
-- stationery than to find the wrong thing confidently.
function Skin.inboxPaper()
    for _, name in ipairs(INBOX_REGIONS) do
        local region = _G[name]
        if textureOf(region) then return region, name end
    end

    local best, bestArea, bestFrom
    for _, name in ipairs({ "InboxFrame" }) do
        local frame = _G[name]
        if frame and frame.GetRegions then
            local ok, regions = pcall(function() return { frame:GetRegions() } end)
            if ok then
                for _, region in ipairs(regions) do
                    local regionName = (region.GetName and region:GetName() or ""):lower()
                    if textureOf(region) and regionName:find("bg")
                        and not matches(regionName, NOT_PAPER) then
                        local size = area(region)
                        if not best or size > bestArea then
                            best, bestArea, bestFrom = region, size, name .. "." .. regionName
                        end
                    end
                end
            end
        end
    end
    if best then return best, bestFrom end
    return nil
end

-- The stationery halves, if the client has drawn a letter yet.
function Skin.stationery()
    prime()
    for _, pair in ipairs(STATIONERY_PAIRS) do
        local left, right = _G[pair[1]], _G[pair[2]]
        if textureOf(left) then
            -- One half is still paper: a sheet drawn from it twice beats no sheet at all.
            return left, (textureOf(right) and right or left), pair[1]
        end
    end
    return nil
end

-- The largest background-looking region on anything the client has drawn, or nil.
function Skin.background()
    -- Zero, not nil: the first region reached compares its size against this.
    local best, bestArea, bestFrom = nil, 0, nil

    for _, name in ipairs(PARCHMENT_SOURCES) do
        local frame = _G[name]
        if frame and frame.GetRegions then
            local ok, regions = pcall(function() return { frame:GetRegions() } end)
            if ok then
                for _, region in ipairs(regions) do
                    local regionName = (region.GetName and region:GetName() or ""):lower()
                    if regionName ~= "" and textureOf(region)
                        and matches(regionName, STRONG_NAMES)
                        and not matches(regionName, NOT_PAPER) then
                        local size = area(region)
                        if not best or size > bestArea then
                            best, bestArea, bestFrom = region, size, name
                        end
                    end
                end
            end
        end
    end

    if best then return best, bestFrom end
    return nil
end

-- Laying the pieces out ---------------------------------------------------------

local function hideAll(frame)
    for _, piece in ipairs(frame.paper) do
        piece:Hide()
        piece:ClearAllPoints()
        if piece.SetTexCoord then piece:SetTexCoord(0, 1, 0, 1) end
    end
end

local function anchorWhole(frame)
    frame.paper[1]:SetAllPoints(frame.parchmentBacking)
end

-- Split where Blizzard splits it, not down the middle.
--
-- The letter's two halves are not halves: on this client the left is 252 wide and the
-- right is 64, because the right one is the torn edge of the page. Cutting our sheet 50/50
-- squeezes the writing surface and drops the tear two thirds of the way across, which is
-- what the page looked like and why it read as wrong.
local function anchorHalves(frame, ratio)
    local backing = frame.parchmentBacking
    local split = math.floor((frame:GetWidth() or 0) * (ratio or 0.5) + 0.5)

    frame.paper[1]:SetPoint("TOPLEFT", backing, "TOPLEFT")
    frame.paper[1]:SetPoint("BOTTOMRIGHT", backing, "BOTTOMLEFT", split, 0)
    frame.paper[2]:SetPoint("TOPLEFT", backing, "TOPLEFT", split, 0)
    frame.paper[2]:SetPoint("BOTTOMRIGHT", backing, "BOTTOMRIGHT")
end

-- Top left, top right, bottom left, bottom right - the order MATERIAL_CORNERS is in.
local function anchorQuads(frame)
    local backing = frame.parchmentBacking
    frame.paper[1]:SetPoint("TOPLEFT", backing, "TOPLEFT")
    frame.paper[1]:SetPoint("BOTTOMRIGHT", backing, "CENTER")
    frame.paper[2]:SetPoint("TOPLEFT", backing, "TOP")
    frame.paper[2]:SetPoint("BOTTOMRIGHT", backing, "RIGHT")
    frame.paper[3]:SetPoint("TOPLEFT", backing, "LEFT")
    frame.paper[3]:SetPoint("BOTTOMRIGHT", backing, "BOTTOM")
    frame.paper[4]:SetPoint("TOPLEFT", backing, "CENTER")
    frame.paper[4]:SetPoint("BOTTOMRIGHT", backing, "BOTTOMRIGHT")
end

-- Dresses a frame in whatever paper this client turned out to have. Returns true if a real
-- texture was found, false if it is running on colour alone.
-- `kind` says which source to reach for FIRST. Everything else stays as a fallback, so a
-- client missing one still gets paper rather than a hole.
--
--   "inbox"       the sheet the inbox fills its inset with - the list view
--   "stationery"  the page a letter is written on - the claim view, which is send mail
local function dress(frame)
    hideAll(frame)

    frame.dressedKind = nil

    if frame.kind == "inbox" then
        local region, from = Skin.inboxPaper()
        if region then
            anchorWhole(frame)
            copyTexture(frame.paper[1], region)
            frame.paper[1]:Show()
            frame.dressedKind = "inbox"
            Skin.using.inbox = from .. "  (" .. tostring(describeTexture(region)) .. ")"
            return true
        end

        -- Failing that, the LEFT half of the letter page, stretched over the whole sheet.
        --
        -- Deliberately only the left half: the right one is the torn edge, and a list
        -- wearing it ends up with a rip down the middle of itself. The left half is plain
        -- paper, which is what the inbox is.
        local left = Skin.stationery()
        if left then
            anchorWhole(frame)
            -- WITH the crop it came with. Resetting the coords to 0,1,0,1 showed the
            -- whole file instead of the paper inside it, and the rest of that file is
            -- empty - which is why the sheet measured 321 wide and drew about 190.
            copyTexture(frame.paper[1], left)
            frame.paper[1]:Show()
            frame.dressedKind = "inbox"
            Skin.using.inbox = "stationery left half, stretched  (" ..
                tostring(describeTexture(left)) .. ")"
            return true
        end
    end

    if frame.kind == "stationery" then
        local left, right, from = Skin.stationery()
        if left then
            -- The halves in the proportion the source has them, so the tear lands on the
            -- edge of the page rather than in the middle of the writing.
            local leftWidth = (left.GetWidth and left:GetWidth()) or 1
            local rightWidth = (right ~= left and right.GetWidth and right:GetWidth()) or 0
            local total = leftWidth + rightWidth
            anchorHalves(frame, total > 0 and (leftWidth / total) or 0.5)

            copyTexture(frame.paper[1], left)
            copyTexture(frame.paper[2], right)
            frame.paper[1]:Show()
            frame.paper[2]:Show()
            frame.dressedKind = "stationery"
            Skin.using.stationery = from .. "  (" .. tostring(describeTexture(left)) .. ")"
            return true
        end
    end

    local corners, owner = Skin.material()
    if corners then
        anchorQuads(frame)
        local ok = true
        for index, corner in ipairs(corners) do
            ok = copyTexture(frame.paper[index], corner) and ok
            frame.paper[index]:Show()
        end
        if ok then
            frame.dressedKind = "material"
            Skin.using.parchment = "quest material, off " .. owner ..
                "  (" .. tostring(describeTexture(corners[1])) .. ")"
            return true
        end
        hideAll(frame)
    end

    local left, right, from = Skin.stationery()
    if left then
        anchorHalves(frame)
        copyTexture(frame.paper[1], left)
        copyTexture(frame.paper[2], right)
        frame.paper[1]:Show()
        frame.paper[2]:Show()
        frame.dressedKind = "stationery"
        Skin.using.parchment = "stationery, off " .. from ..
            "  (" .. tostring(describeTexture(left)) .. ")"
        return true
    end

    local region, source = Skin.background()
    if region then
        anchorWhole(frame)
        copyTexture(frame.paper[1], region)
        frame.paper[1]:Show()
        frame.dressedKind = "background"
        Skin.using.parchment = "background, off " .. source .. "." ..
            (region:GetName() or "?") .. "  (" .. tostring(describeTexture(region)) .. ")"
        return true
    end

    Skin.using.parchment = "none found yet; paper colour only"
    return false
end

-- A sheet of paper, as its own frame, for a caller that wants to anchor it somewhere
-- specific rather than over everything.
--
-- The claim view needs this: send mail papers only its letter body and leaves the rest on
-- the frame's own dark chrome, so a panel-wide sheet is the wrong shape for it.
function Skin.sheet(parent, kind, level)
    local sheet = CreateFrame("Frame", nil, parent)
    sheet.kind = kind
    if level then sheet:SetFrameLevel(math.max(0, (parent:GetFrameLevel() or 0) + level)) end
    Skin.parchment(sheet, 0, kind)
    return sheet
end

-- Dresses a sheet again. `force` re-anchors even when the source has not changed, which
-- is what a caller does after resizing one: the halves are split at a pixel offset, and
-- that offset is wrong the moment the sheet is a different width.
function Skin.redress(sheet, force)
    if not sheet or not sheet.paper then return false end
    if not force and sheet.dressedKind and sheet.dressedKind == sheet.kind then
        return true
    end
    return dress(sheet)
end

-- Lays the parchment into a frame.
function Skin.parchment(frame, inset, kind)
    inset = inset or 0
    frame.kind = kind or frame.kind

    -- An anchor, and nothing else. It used to be filled paper-colour so that a client
    -- which yielded no texture still read as a page, but now that the stationery is found
    -- reliably that fill only ever showed where the real paper did not reach - a band of
    -- flat tan beside the sheet. Invisible: either the paper covers the panel or the
    -- host's own background does.
    local backing = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    backing:SetPoint("TOPLEFT", inset, -inset)
    backing:SetPoint("BOTTOMRIGHT", -inset, inset)
    backing:SetColorTexture(0, 0, 0, 0)
    frame.parchmentBacking = backing

    -- Four pieces, because the best source comes in four. A layout needing fewer hides the
    -- rest rather than building a different set.
    frame.paper = {}
    for index = 1, 4 do
        local piece = frame:CreateTexture(nil, "BACKGROUND")
        piece:Hide()
        frame.paper[index] = piece
    end

    local dressed = dress(frame)

    -- Re-dressed until it gets what it asked for, not merely until it has something.
    --
    -- The old guard was "is anything showing", which meant a sheet that fell back to the
    -- inbox's paper because the send mail frame had not been drawn yet kept that paper
    -- forever. A claim view wearing the inbox's background is exactly the failure that
    -- guard was hiding.
    local function retry()
        Skin.redress(frame)
    end

    frame:HookScript("OnShow", retry)

    -- And whenever the client draws a letter or a quest of its own, because that is the
    -- moment these textures stop being empty.
    for _, name in ipairs({ "SendMailFrame", "OpenMailFrame", "QuestFrame",
                            "QuestFrameDetailPanel", "QuestLogDetailFrame" }) do
        local other = _G[name]
        if other and other.HookScript then
            pcall(other.HookScript, other, "OnShow", function()
                Skin.primed = false
                retry()
            end)
        end
    end

    frame.parchment = frame.paper[1]
    return dressed
end

-- Item buttons ---------------------------------------------------------------

-- ItemButtonTemplate first, and deliberately so. QuestItemTemplate is closer to what the
-- quest reward row uses, but it carries a name plate sized for a quest layout, which beside
-- a 37px icon draws as a black slab. What this panel wants from a template is the icon
-- frame and nothing else.
local ITEM_TEMPLATES = {
    "ItemButtonTemplate",
    "QuestItemTemplate",
    "LargeItemButtonTemplate",
}

local function iconOf(button, name)
    return button.icon or button.Icon
        or (name and _G[name .. "IconTexture"])
        or (button.GetName and _G[(button:GetName() or "") .. "IconTexture"])
end

local function countOf(button, name)
    return button.Count or (name and _G[name .. "Count"])
        or (button.GetName and _G[(button:GetName() or "") .. "Count"])
end

-- Builds one item button. Returns the button; it always works, because a hand-rolled one
-- is waiting behind the templates.
function Skin.itemButton(parent, name, size)
    size = size or 37

    local button, used
    for _, template in ipairs(ITEM_TEMPLATES) do
        local ok, built = pcall(CreateFrame, "Button", name, parent, template)
        if ok and built then button, used = built, template break end
    end

    if not button then
        button = CreateFrame("Button", name, parent)
        used = "hand-rolled"
    end
    Skin.using.itemButton = used

    button:SetSize(size, size)

    local icon = iconOf(button, name)
    if not icon then
        icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
    end
    button.grIcon = icon

    local count = countOf(button, name)
    if not count then
        count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        count:SetPoint("BOTTOMRIGHT", -2, 2)
    end
    button.grCount = count

    -- Behind the icon, not over it. A solid rectangle on OVERLAY is a solid rectangle:
    -- the first build painted every reward icon flat green.
    if not button.grBorder then
        local border = button:CreateTexture(nil, "BACKGROUND", nil, 1)
        border:SetPoint("TOPLEFT", -2, 2)
        border:SetPoint("BOTTOMRIGHT", 2, -2)
        border:SetColorTexture(0, 0, 0, 0)
        button.grBorder = border
    end

    -- Whatever else the template brought. A name plate, a stock border or a slot backdrop
    -- sized for somebody else's layout is the black slab that showed up beside the icon.
    for _, extra in ipairs({ "NameFrame", "Name", "IconBorder", "SlotTexture", "Stock" }) do
        local region = button[extra] or (name and _G[name .. extra])
        if region and region.Hide then region:Hide() end
    end

    -- Every script the template brought is replaced here. This is the line that makes
    -- borrowing a quest template safe outside a quest.
    button:SetScript("OnEnter", nil)
    button:SetScript("OnLeave", nil)
    button:SetScript("OnClick", nil)
    button:SetScript("OnUpdate", nil)
    button:RegisterForClicks("LeftButtonUp")

    return button
end

-- The empty-slot art Send Mail draws under its attachments.
--
-- Copied off SendMailAttachment1 rather than named, like everything else here. An empty
-- slot is not nothing: it is the shape that tells a player something is meant to go there,
-- and a claim with three slots showing is a claim that says what it wants at a glance.
local SLOT_FALLBACK = "Interface\\Buttons\\UI-Slot-Background"

-- The engraved square an empty mail slot is drawn as. Send Mail's attachments first, the
-- inbox's letter buttons second - both draw the same rune, and between them one of the two
-- has been laid out whatever the player has been doing.
local SLOT_SOURCES = { "SendMailAttachment1", "MailItem1Button", "SendMailAttachment2" }

function Skin.slotSource()
    for _, name in ipairs(SLOT_SOURCES) do
        local button = _G[name]
        local texture = button and button.GetNormalTexture and button:GetNormalTexture()
        if textureOf(texture) then return texture, name end
    end
    return nil
end

-- Puts that square on a button, as its normal texture - which is where Blizzard puts it.
function Skin.slotArt(button)
    local source, from = Skin.slotSource()
    local kind, value = textureOf(source)

    if kind == "atlas" and button.SetNormalAtlas then
        if pcall(button.SetNormalAtlas, button, value) then
            Skin.using.slot = "atlas:" .. value .. "  (" .. from .. ")"
            return true
        end
    elseif kind == "file" then
        if pcall(button.SetNormalTexture, button, value) then
            Skin.using.slot = tostring(value) .. "  (" .. from .. ")"
            return true
        end
    end

    pcall(button.SetNormalTexture, button, SLOT_FALLBACK)
    Skin.using.slot = SLOT_FALLBACK .. "  (fallback)"
    return false
end

-- Fills a mail slot in. Unlike setItem, an empty one stays visible: the slot itself is
-- information.
function Skin.setSlot(button, itemID, quantity, quality)
    if itemID then
        -- The item becomes the button's NORMAL texture, replacing the rune. Drawing the
        -- icon as a separate layer on top of the slot art is what clipped it to a sliver:
        -- both were in ARTWORK, and the slot won.
        local texture
        if type(GetItemInfo) == "function" then
            texture = select(10, GetItemInfo(itemID))
        end
        pcall(button.SetNormalTexture, button,
            texture or "Interface\\Icons\\INV_Misc_QuestionMark")

        button.grIcon:Hide()
        button.grCount:SetText((quantity or 1) > 1 and quantity or "")
        button.grBorder:SetColorTexture(0, 0, 0, 0)
        button.grItemID = itemID

        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if GameTooltip.SetItemByID then
                pcall(GameTooltip.SetItemByID, GameTooltip, self.grItemID)
            else
                GameTooltip:AddLine("item " .. tostring(self.grItemID), 1, 1, 1)
            end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        button:SetScript("OnClick", function(self)
            local _, link = GetItemInfo(self.grItemID)
            if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
        end)
        button:Show()
        return
    end

    -- Empty: the rune comes back.
    Skin.slotArt(button)
    button.grIcon:Hide()
    button.grCount:SetText("")
    button.grBorder:SetColorTexture(0, 0, 0, 0)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Empty slot", 1, 1, 1)
        GameTooltip:AddLine("This offer does not need anything here.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnClick", nil)
    button:Show()
end

-- Fills one in. `itemID` may be nil, which hides it.
function Skin.setItem(button, itemID, quantity, quality)
    if not itemID then
        button:Hide()
        return
    end

    local texture
    if type(GetItemInfo) == "function" then
        texture = select(10, GetItemInfo(itemID))
    end
    button.grIcon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    button.grIcon:Show()
    button.grCount:SetText((quantity or 1) > 1 and quantity or "")

    if quality then
        local r, g, b = Skin.qualityColor(quality)
        button.grBorder:SetColorTexture(r, g, b, 0.85)
    else
        button.grBorder:SetColorTexture(0, 0, 0, 0)
    end

    button.grItemID = itemID

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then
            pcall(GameTooltip.SetItemByID, GameTooltip, self.grItemID)
        else
            GameTooltip:AddLine("item " .. tostring(self.grItemID), 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Shift-clicking a reward into chat is what every other item icon in the game does,
    -- and somebody asking "is this worth it" in guild chat is the point.
    button:SetScript("OnClick", function(self)
        local _, link = GetItemInfo(self.grItemID)
        if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
    end)

    button:Show()
end

-- Money ----------------------------------------------------------------------

local MONEY_TEMPLATES = { "SmallMoneyFrameTemplate", "MoneyFrameTemplate" }

local moneyCounter = 0

-- The coin widget the whole default UI uses, or a plain string if this client has no money
-- template. Returns a frame with :Set(copper).
function Skin.moneyFrame(parent)
    moneyCounter = moneyCounter + 1
    local name = "GuildLedgerMoney" .. moneyCounter

    for _, template in ipairs(MONEY_TEMPLATES) do
        local ok, frame = pcall(CreateFrame, "Frame", name, parent, template)
        if ok and frame then
            frame.small = 1
            if MoneyFrame_SetType then pcall(MoneyFrame_SetType, frame, "STATIC") end
            Skin.using.money = template
            frame.Set = function(self, copper)
                if MoneyFrame_Update then
                    pcall(MoneyFrame_Update, name, copper or 0)
                end
                self:SetShown((copper or 0) > 0)
            end
            return frame
        end
    end

    -- No coin icons, so the words instead. Resolve.money already formats copper the way
    -- the rest of this addon prints it.
    local holder = CreateFrame("Frame", name, parent)
    holder:SetSize(120, 14)
    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT")
    Skin.using.money = "text (no money template on this client)"
    holder.Set = function(self, copper)
        text:SetText(GBA.Resolve.money(copper or 0))
        self:SetShown((copper or 0) > 0)
    end
    return holder
end

-- Quality --------------------------------------------------------------------

-- The client's own colours first, so a reward tier and an item of that tier are the same
-- colour on screen. The pure table in Reward is the fallback, and holds the same numbers.
function Skin.qualityColor(quality)
    if type(GetItemQualityColor) == "function" then
        local ok, r, g, b = pcall(GetItemQualityColor, quality or 1)
        if ok and r then return r, g, b end
    end
    local colour = GBA.Reward.qualityColor(quality)
    return colour[1], colour[2], colour[3]
end

-- A scrolling body ------------------------------------------------------------

-- A scroll frame with a child to hang content on. Blizzard's template if it is there,
-- which brings the bar, the buttons and the mouse wheel with it.
function Skin.scrollBody(parent, name, width, height, keepBar)
    local scroll
    -- Named, and not optionally: UIPanelScrollFrameTemplate's OnLoad finds its own scroll
    -- bar through _G[self:GetName() .. "ScrollBar"], which on an unnamed frame is a
    -- concatenation of nil and takes the whole panel down with it.
    local ok, built = pcall(CreateFrame, "ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    if ok and built then
        scroll = built
        Skin.using.scroll = "UIPanelScrollFrameTemplate"
    else
        scroll = CreateFrame("ScrollFrame", name, parent)
        Skin.using.scroll = "plain ScrollFrame (no template)"
    end
    scroll:SetSize(width, height)

    -- The bar is kept where the frame being copied has one. Send Mail's letter body does,
    -- and it is what lets an offer say more than fits on a page - so the claim view asks
    -- for it, and the list, whose model is the inbox, does not.
    if name and not keepBar then
        for _, part in ipairs({ "ScrollBar", "ScrollBarScrollUpButton",
                                "ScrollBarScrollDownButton", "ScrollBarThumbTexture" }) do
            local region = _G[name .. part]
            if region and region.Hide then region:Hide() end
        end
    end
    -- Honoured. UIPanelScrollFrameTemplate brings WoW's own scroll bar and that is the one
    -- we want - not a copy of it, and not Blizzard's mail bar rebound to our frame. This
    -- line ignored keepBar and hid it two lines after the loop above had kept it.
    if not keepBar and scroll.ScrollBar and scroll.ScrollBar.Hide then
        scroll.ScrollBar:Hide()
    end

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(width, height)
    scroll:SetScrollChild(child)
    scroll.child = child

    return scroll
end

-- Blizzard's own furniture, borrowed whole ------------------------------------

-- The first of these globals the client actually has. Everything below reaches for
-- Blizzard's frames by name, and a name that is right on one client is absent on the next,
-- so nothing here asks for one name and hopes.
function Skin.firstOf(...)
    for _, name in ipairs({ ... }) do
        local frame = _G[name]
        if frame then return frame, name end
    end
    return nil
end

-- Anchors one of ours onto one of Blizzard's, so it is not merely near it - it IS there,
-- and stays there when Blizzard moves.
--
-- This is what replaced measuring. The old code read GetLeft off Blizzard's frames and
-- copied the numbers into our own SetPoint calls, which is right exactly until the frame
-- being copied has not been laid out yet - and /gba wireframe caught SendMailBodyEditBox and
-- SendMailScrollFrame reporting no rectangle at all on this client. An anchor does not
-- care: it is a relationship the layout engine resolves whenever it next runs, so a frame
-- that has never been drawn still lands in the right place once it is.
--
-- `panel` is the fallback home for the standalone window, which has no mail frame behind it
-- to anchor to. There the Blizzard frame is measured against MailFrame once and the offset
-- used directly, because a window sitting beside the mailbox cannot borrow its coordinates.
-- dx/dy are an offset ON TOP of the source, for the parts that sit inside Blizzard's own
-- rather than on it - a sender line is inset a few units into the edit box holding it.
-- `fallback` is {x=,y=} against the panel, used only when the client has no such frame at
-- all, which is a different case from having one somewhere else.
function Skin.anchorTo(target, sourceName, panel, dx, dy, fallback)
    dx, dy = dx or 0, dy or 0
    local source = _G[sourceName]
    target:ClearAllPoints()

    -- Placed, not merely present. This distinction cost a round: InboxFrameBg exists and
    -- carries the inbox's parchment, but it has no rectangle of its own, and a sheet anchored
    -- to it inherited that - it drew nowhere at all. A frame that has a texture and no
    -- position is one the client does not lay out, and anchoring into it is anchoring into
    -- nothing.
    --
    -- Falling back here is not a loss even when the frame is merely late: the fallback
    -- coordinates are the measured ones, and anchorAll runs on every refresh, so the anchor
    -- takes over by itself the first time Blizzard does lay the frame out.
    if source and (not panel or panel.embedded ~= false)
        and source.GetLeft and source:GetLeft() then
        target:SetPoint("TOPLEFT", source, "TOPLEFT", dx, dy)
        return true
    end

    -- Standalone: Blizzard's frame is somewhere else on screen entirely, so its position
    -- relative to the mail frame is copied onto our panel instead.
    local mail = _G.MailFrame
    if source and mail and source.GetLeft and source:GetLeft() and mail:GetLeft() then
        target:SetPoint("TOPLEFT", panel, "TOPLEFT",
            math.floor(source:GetLeft() - mail:GetLeft() + 0.5) + dx,
            math.floor(source:GetTop() - mail:GetTop() + 0.5) + dy)
        return true
    end

    fallback = fallback or { x = 0, y = 0 }
    target:SetPoint("TOPLEFT", panel or target:GetParent(), "TOPLEFT",
        fallback.x + dx, fallback.y + dy)
    return false
end

-- Inbox rows ------------------------------------------------------------------

-- MailItemTemplate, confirmed present on this client by
--   /run print(pcall(CreateFrame,"Button","GRProbeRow",UIParent,"MailItemTemplate"))
-- which answered true. The list still tries a chain rather than naming one, for the same
-- reason every other template here does: this addon runs on clients nobody has probed.
local ROW_TEMPLATES = {
    "MailItemTemplate",
    "InboxFrameItemTemplate",
}

-- What MailItemTemplate calls its own parts. Convention says $parentSubject and friends,
-- and the existing SLOT_SOURCES already relies on MailItem1Button and MailItem1ButtonIcon
-- being real, so the convention holds at least that far. The rest is discovered rather
-- than assumed, and /gba uiprobe prints what was found - a row that is missing its sender
-- line should say so, not paint nothing and look like a bug in the data.
local ROW_PARTS = {
    button  = { "Button" },
    icon    = { "ButtonIcon", "ButtonIconTexture" },
    count   = { "ButtonCount" },
    subject = { "Subject" },
    sender  = { "Sender" },
    expires = { "ExpireTime", "Expire" },
}

-- Which suffix answered for each part, filled in by the first row built, for the probe.
Skin.rowParts = {}

local function discoverParts(row, name)
    local found = {}
    for part, suffixes in pairs(ROW_PARTS) do
        for _, suffix in ipairs(suffixes) do
            local region = _G[name .. suffix]
            if region then
                found[part] = region
                Skin.rowParts[part] = suffix
                break
            end
        end
        if Skin.rowParts[part] == nil then Skin.rowParts[part] = false end
    end
    return found
end

-- One inbox row, built from Blizzard's own template and then disarmed.
--
-- Disarmed is the whole of the care here. MailItemTemplate's scripts are inbox scripts:
-- its OnClick calls InboxFrame_OnClick and its OnEnter reads GetInboxHeaderInfo(self.index),
-- both of which index Blizzard's mail data by a row number that means nothing on our list.
-- Left in place they do not merely misbehave, they error on the first mouseover. The
-- template is taken for its LOOK - the divider rule, the icon frame, the three text lines
-- on the grid the inbox puts them on - and every script it carried is replaced by ours.
function Skin.rowButton(parent, name)
    local row, used
    for _, template in ipairs(ROW_TEMPLATES) do
        local ok, built = pcall(CreateFrame, "Button", name, parent, template)
        if ok and built then row, used = built, template break end
    end

    if not row then
        row = CreateFrame("Button", name, parent)
        used = "hand-rolled"
    end
    Skin.using.row = used

    for _, script in ipairs({ "OnClick", "OnEnter", "OnLeave", "OnUpdate",
                              "OnDragStart", "OnDragStop", "OnMouseDown", "OnMouseUp" }) do
        row:SetScript(script, nil)
    end
    row:RegisterForClicks("LeftButtonUp")

    -- And whatever the template's OnLoad signed it up for. A row that is still listening
    -- for MAIL_INBOX_UPDATE will act on Blizzard's mail arriving, against our data.
    row:SetScript("OnEvent", nil)
    if row.UnregisterAllEvents then pcall(row.UnregisterAllEvents, row) end

    row.parts = discoverParts(row, name)

    -- The template's own status furniture belongs to a letter, not an offer: an unread
    -- flash, a COD tag and a returned stamp have no meaning on a reward.
    for _, extra in ipairs({ "Unread", "Highlighted", "CODFlash", "Flash", "StatusIcon" }) do
        local region = _G[name .. extra] or row[extra]
        if region and region.Hide then
            region:Hide()
            if region.SetScript then pcall(region.SetScript, region, "OnUpdate", nil) end
        end
    end

    return row
end

-- Send Mail's header rows ------------------------------------------------------

-- The bordered box Send Mail puts To and Subject in.
--
-- Same treatment as the inbox rows: Blizzard's own widget, taken for its LOOK and then
-- disarmed. A From line drawn as bare text on the frame is the difference you can see
-- between the two frames side by side - Send Mail's fields are sunken boxes with a border,
-- and a fontstring floating where one should be reads as a field that is missing.
local INPUT_TEMPLATES = {
    "InputBoxTemplate",
    "SearchBoxTemplate",
}

function Skin.inputBox(parent, name)
    local box, used
    for _, template in ipairs(INPUT_TEMPLATES) do
        local ok, built = pcall(CreateFrame, "EditBox", name, parent, template)
        if ok and built then box, used = built, template break end
    end

    if not box then
        box = CreateFrame("EditBox", name, parent)
        used = "hand-rolled"
    end
    Skin.using.inputBox = used

    -- Read, not typed in. These hold who posted the offer and what it is called, neither of
    -- which the player may change - so the box keeps the art and gives up the keyboard.
    box:SetAutoFocus(false)
    box:EnableKeyboard(false)
    box:EnableMouse(false)
    for _, script in ipairs({ "OnEnterPressed", "OnEscapePressed", "OnEditFocusGained",
                              "OnEditFocusLost", "OnTextChanged", "OnTabPressed" }) do
        box:SetScript(script, nil)
    end

    return box
end

-- Sets one, and puts it back to the start. An edit box holds its cursor where it was left,
-- so a name longer than the box shows its END - "...-Skull Rock" - unless it is wound back.
function Skin.setInput(box, text)
    box:SetText(text or "")
    if box.SetCursorPosition then pcall(box.SetCursorPosition, box, 0) end
end

-- Every state of a button's art, not just the one it is resting in. copyButtonArt takes
-- the normal texture alone, which is all a slot needs; a page button that is pressed and
-- disabled as well needs the other three or it flickers back to nothing on the first click.
function Skin.copyButton(target, sourceName)
    local source = _G[sourceName]
    if not source then return false end

    local copied = false
    local states = {
        { get = "GetNormalTexture",    set = "SetNormalTexture",    atlas = "SetNormalAtlas" },
        { get = "GetPushedTexture",    set = "SetPushedTexture",    atlas = "SetPushedAtlas" },
        { get = "GetDisabledTexture",  set = "SetDisabledTexture",  atlas = "SetDisabledAtlas" },
        { get = "GetHighlightTexture", set = "SetHighlightTexture", atlas = "SetHighlightAtlas" },
    }

    for _, state in ipairs(states) do
        local from = source[state.get] and source[state.get](source)
        local kind, value = textureOf(from)
        if kind == "file" then
            if pcall(target[state.set], target, value) then copied = true end
        elseif kind == "atlas" and target[state.atlas] then
            if pcall(target[state.atlas], target, value) then copied = true end
        end
    end

    if source.GetWidth and source:GetWidth() then
        target:SetSize(source:GetWidth(), source:GetHeight())
    end
    return copied
end

-- What this client actually gave us -------------------------------------------

