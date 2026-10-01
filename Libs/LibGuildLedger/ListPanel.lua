-- A plain status panel for a mail tab: a heading, scrolling lines of text, and a row of buttons.
-- Shared by the client's Sent tab and the officer's Vault tab, which are both "here is where
-- things stand, and here is what you can do about it".
--
-- It refreshes itself every two seconds while shown, because what it describes (sessions in
-- flight, letters being opened) changes without the player doing anything.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if not ns or not ns.loading then return end

local ListPanel = {}
ns.ListPanel = ListPanel

-- host: the mail frame. spec: { title, lines = function() -> { "text", ... },
-- buttons = { { label, onClick } } }. Returns the panel for MailTabs.
function ListPanel.new(host, spec)
    local panel = CreateFrame("Frame", nil, host)
    panel:SetAllPoints(host)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", host, "TOP", 10, -46)
    title:SetText(spec.title or "")

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", host, "TOPLEFT", 26, -78)
    scroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -66, 128)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(280, 10)
    scroll:SetScrollChild(content)

    local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    text:SetWidth(280)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetSpacing(3)

    local previous
    for i, b in ipairs(spec.buttons or {}) do
        local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        button:SetSize(140, 22)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        else
            button:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 24, 100)
        end
        button:SetText(b.label)
        button:SetScript("OnClick", function()
            local ok, err = pcall(b.onClick)
            if not ok then ns.Print("|cffff4040" .. tostring(err) .. "|r") end
            panel.refresh()
        end)
        previous = button
    end

    function panel.refresh()
        local ok, lines = pcall(spec.lines)
        if not ok then lines = { "|cffff4040could not read the status:|r " .. tostring(lines) } end
        text:SetText(table.concat(lines or {}, "\n"))
        content:SetHeight(math.max(10, (text:GetStringHeight() or 10) + 8))
    end

    local elapsed = 0
    panel:SetScript("OnShow", function() elapsed = 0; panel.refresh() end)
    panel:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed >= 2 then elapsed = 0; panel.refresh() end
    end)
    return panel
end

-- Colours, so both tabs speak the same way.
ListPanel.GOOD = "|cff40ff40"
ListPanel.WAIT = "|cffffcc00"
ListPanel.BAD = "|cffff4040"
ListPanel.DIM = "|cff808080"
ListPanel.END = "|r"
