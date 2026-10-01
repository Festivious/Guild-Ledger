-- Choosing an offer's icon, from the game's own list.
--
-- Nothing here is a hand-written list of texture paths. GetMacroIcons and GetMacroItemIcons
-- fill a table with every icon the client actually has - the same source the macro window
-- browses - so the picker stays correct across patches without anybody maintaining it, and
-- an icon that exists in the game is an icon that can be chosen.
--
-- The window is our own rather than MacroPopupFrame reused. That frame is wired to macro
-- state: opening it sets the macro being edited, and its accept button writes to a macro
-- slot. Borrowing it would mean either leaving those hooks live or unpicking them, and
-- unpicking somebody else's frame is how you break their feature. The LIST is the part worth
-- borrowing, and that comes down an API.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Picker = {}
ns.IconPicker = Picker

local COLUMNS, ROWS = 10, 6
local SIZE, GAP = 36, 4
local PER_PAGE = COLUMNS * ROWS

-- The engraved square an empty slot is drawn as, copied off Send Mail's own attachment
-- rather than named - same rule as everything else on these frames. The path is only
-- reached on a client that has not drawn a mail frame yet.
local EMPTY_SLOT = "Interface\\Buttons\\UI-Slot-Background"

function Picker.slotArt(button)
    local source = _G.SendMailAttachment1
    local texture = source and source.GetNormalTexture and source:GetNormalTexture()
    local file = texture and texture.GetTexture and texture:GetTexture()
    if file then
        pcall(button.SetNormalTexture, button, file)
    else
        pcall(button.SetNormalTexture, button, EMPTY_SLOT)
    end
end

-- Every icon the client has. Two calls, because items and spells come from different lists
-- and an offer for a bag should be able to look like that bag.
local icons = nil

local function gather()
    if icons then return icons end

    icons = {}
    if type(GetMacroIcons) == "function" then pcall(GetMacroIcons, icons) end
    if type(GetMacroItemIcons) == "function" then pcall(GetMacroItemIcons, icons) end

    -- Older clients count and index instead of filling a table.
    if #icons == 0 and type(GetNumMacroIcons) == "function" then
        for index = 1, (GetNumMacroIcons() or 0) do
            icons[#icons + 1] = index
        end
    end
    return icons
end

local frame, onPick, query = nil, nil, ""

-- Whether the client's icons have names to search at all.
--
-- On this engine GetMacroIcons hands back file IDs - numbers - which carry no text. Nothing
-- can match against a number, and the only way other addons offer a search here is by
-- shipping a hand-maintained table of icon names, which is exactly the thing not to do: it
-- goes stale every patch and it is a list somebody has to type. So the box is offered when
-- the client gives paths and switched off, with a reason, when it gives numbers.
local function searchable()
    local list = gather()
    return type(list[1]) == "string"
end

local function matching()
    local list = gather()
    if query == "" or not searchable() then return list end

    local out = {}
    for _, icon in ipairs(list) do
        if tostring(icon):lower():find(query, 1, true) then out[#out + 1] = icon end
    end
    return out
end

local function refresh()
    local list = matching()
    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(frame.scroll) or 0

    if FauxScrollFrame_Update then
        FauxScrollFrame_Update(frame.scroll, math.ceil(#list / COLUMNS), ROWS, SIZE + GAP)
    end

    for index, button in ipairs(frame.buttons) do
        local at = index + offset * COLUMNS
        local icon = list[at]
        if icon then
            button.icon:SetTexture(icon)
            button.value = icon
            button:Show()
        else
            button:Hide()
        end
    end

    frame.count:SetText(string.format("%d icons", #list))
end

local function build()
    if frame then return frame end

    frame = CreateFrame("Frame", "GuildLedgerIconPicker", UIParent, "DialogBoxFrame")
    frame:SetSize(COLUMNS * (SIZE + GAP) + 40, ROWS * (SIZE + GAP) + 108)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Pick an icon")

    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.count:SetPoint("TOPRIGHT", -22, -16)

    frame.search = CreateFrame("EditBox", "GuildLedgerIconPickerSearch", frame,
        "InputBoxTemplate")
    frame.search:SetSize(COLUMNS * (SIZE + GAP) - 90, 20)
    frame.search:SetPoint("TOPLEFT", 22, -36)
    frame.search:SetAutoFocus(false)
    frame.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.search:SetScript("OnTextChanged", function(self)
        query = (self:GetText() or ""):lower()
        if frame.scroll and FauxScrollFrame_SetOffset then
            FauxScrollFrame_SetOffset(frame.scroll, 0)
            _G[frame.scroll:GetName() .. "ScrollBar"]:SetValue(0)
        end
        refresh()
    end)

    if not searchable() then
        frame.search:Disable()
        frame.search:SetText("")
        frame.search:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("This client lists its icons by number", 1, 1, 1)
            GameTooltip:AddLine("There is no name to search against. Scroll instead.",
                0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        frame.search:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local ok, scroll = pcall(CreateFrame, "ScrollFrame", "GuildLedgerIconPickerScroll",
        frame, "FauxScrollFrameTemplate")
    frame.scroll = ok and scroll or nil
    if frame.scroll then
        frame.scroll:SetPoint("TOPLEFT", 16, -62)
        frame.scroll:SetSize(COLUMNS * (SIZE + GAP), ROWS * (SIZE + GAP))
        frame.scroll:SetScript("OnVerticalScroll", function(self, offsetY)
            if FauxScrollFrame_OnVerticalScroll then
                FauxScrollFrame_OnVerticalScroll(self, offsetY, SIZE + GAP, refresh)
            end
        end)
    end

    frame.buttons = {}
    for index = 1, PER_PAGE do
        local button = CreateFrame("Button", nil, frame)
        button:SetSize(SIZE, SIZE)
        button:SetPoint("TOPLEFT", 16 + ((index - 1) % COLUMNS) * (SIZE + GAP),
            -62 - math.floor((index - 1) / COLUMNS) * (SIZE + GAP))

        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetAllPoints()

        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 0.92, 0.7, 0.25)

        button:SetScript("OnClick", function(self)
            if onPick then onPick(self.value) end
            frame:Hide()
        end)

        frame.buttons[index] = button
    end

    -- Nothing else on this window. Open it, find one, click it, it closes. Clearing an icon
    -- is done by right-clicking the slot it came from, which is where the icon is.
    return frame
end

-- `pick` is called with a texture the caller stores, or nil for "no icon".
function Picker.open(pick)
    build()
    onPick = pick

    if #gather() == 0 then
        return GBA.Print("|cffffcc00this client will not list its icons|r")
    end

    frame:ClearAllPoints()
    if _G.MailFrame and _G.MailFrame:IsShown() then
        frame:SetPoint("TOPLEFT", _G.MailFrame, "TOPRIGHT", 8, 0)
    else
        frame:SetPoint("CENTER")
    end

    frame:Show()
    query = ""
    if frame.search:IsEnabled() then frame.search:SetText("") end
    refresh()
end

function Picker.close()
    if frame then frame:Hide() end
end
