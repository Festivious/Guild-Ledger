-- What officers add to the analytics frame.
--
-- The frame itself is the member addon's (GuildLedger/UI/Analytics.lua, carried in through
-- Client/Client.xml), so every player has it for their own sessions. An officer's copy gains:
--
--   the Vault layer    what the Vault mail tab showed: keys, and the sessions carried
--   the Quests layer   the hard list, zone by zone, switched on for the guild by officers
--   a Guild source     every session the guild holds, in the session picker
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Analytics = ns.Analytics
if not Analytics then return end

local WIDTH = 480

-- The Vault panel, in its drawer beside the frame ------------------------------------------------

Analytics.addLayer({
    key = "vault", label = "Vault", order = 30,
    icon = "Interface\\Icons\\INV_Misc_Key_03", drawerWidth = 270,
    hint = "Locked sessions this officer holds, and the key letters that open them.",
    build = function(frame, area)
        local vault = CreateFrame("Frame", nil, area, "BackdropTemplate")
        vault:SetPoint("TOPRIGHT", area, "TOPRIGHT", 0, 0)
        vault:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", 0, 0)
        vault:SetWidth(250)
        vault:SetFrameLevel((area:GetFrameLevel() or 0) + 5)
        if vault.SetBackdrop then
            vault:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
            vault:SetBackdropColor(0, 0, 0, 0.85)
        end

        local scroll = CreateFrame("ScrollFrame", nil, vault, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -26, 32)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(214, 10)
        scroll:SetScrollChild(content)
        local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT")
        text:SetWidth(214)
        text:SetJustifyH("LEFT")
        text:SetSpacing(2)

        function vault.refresh()
            local ok, lines = pcall(ns.vaultLines or function() return { "the vault is not loaded" } end)
            if not ok then lines = { "|cffff4040could not read the vault:|r " .. tostring(lines) } end
            text:SetText(table.concat(lines or {}, "\n"))
            content:SetHeight(math.max(10, (text:GetStringHeight() or 10) + 6))
        end

        local previous
        for _, action in ipairs(ns.vaultActions or {}) do
            local b = CreateFrame("Button", nil, vault, "UIPanelButtonTemplate")
            b:SetSize(116, 20)
            if previous then b:SetPoint("LEFT", previous, "RIGHT", 6, 0)
            else b:SetPoint("BOTTOMLEFT", vault, "BOTTOMLEFT", 6, 6) end
            b:SetText(action.label)
            b:SetScript("OnClick", function()
                local ok, err = pcall(action.onClick)
                if not ok then GBA.Print("|cffff4040" .. tostring(err) .. "|r") end
                vault.refresh()
            end)
            previous = b
        end

        local elapsed = 0
        vault:SetScript("OnShow", function() elapsed = 0; vault.refresh() end)
        vault:SetScript("OnUpdate", function(_, dt)
            elapsed = elapsed + (dt or 0)
            if elapsed >= 2 then elapsed = 0; vault.refresh() end
        end)
        vault:Hide()
        return vault
    end,
})

-- The Quests panel: the hard list, zone by zone, one checkbox per quest and one per zone ----------
-- Ticking switches a quest on for the guild (HardSwitches.lua); nothing is on until an officer
-- ticks it, because the guild pays. Spec: 2026-09-25-hard-quest-list-design.md, Part 2.

local function coin(copper)
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

-- What a quest asks, in a few words. Counts only: names come from the item and mob ids, and
-- the note (the row's tooltip) says the rest.
local function asks(entry)
    local parts = {}
    for _, step in ipairs(entry.steps) do
        if step.kind == "kill" then
            local n = step.count or 0
            for _, group in ipairs(step.groups or {}) do n = n + group.count end
            parts[#parts + 1] = "kill " .. n
        elseif step.kind == "mail" then
            parts[#parts + 1] = "mail in " .. step.count
        elseif step.kind == "gather" then
            parts[#parts + 1] = step.count .. " " .. (step.skill == "herb" and "herbs" or step.skill == "mine" and "ore" or "skins")
        elseif step.kind == "craft" then
            local n = 0
            for _, pair in ipairs(step.items) do n = n + pair[2] end
            parts[#parts + 1] = "make " .. n
        else
            parts[#parts + 1] = step.kind
        end
    end
    return table.concat(parts, ", then ")
end

local function pays(entry)
    return entry.pay.copper and coin(entry.pay.copper) or (entry.pay.bagSlots .. "-slot bag")
end

local function zoneName(zone)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(zone)
    return info and info.name or ("zone " .. zone)
end

Analytics.addLayer({
    key = "quests", label = "Quests", order = 31,
    icon = "Interface\\Icons\\INV_Misc_Book_09", drawerWidth = WIDTH - 10,
    hint = "The guild quests officers switch on, zone by zone.",
    build = function(frame, area)
        local quests = CreateFrame("Frame", nil, area, "BackdropTemplate")
        quests:SetAllPoints(area)
        quests:SetFrameLevel((area:GetFrameLevel() or 0) + 10)
        if quests.SetBackdrop then
            quests:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
            quests:SetBackdropColor(0, 0, 0, 0.9)
        end

        local scroll = CreateFrame("ScrollFrame", nil, quests, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -26, 6)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(WIDTH - 50, 10)
        scroll:SetScrollChild(content)

        local note = quests:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        note:SetPoint("TOPLEFT", 10, -8)

        local boxes, y = {}, -4
        local function box(parentY, x, text, sub)
            local b = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
            b:SetSize(20, 20)
            b:SetPoint("TOPLEFT", content, "TOPLEFT", x, parentY)
            b.text = b:CreateFontString(nil, "OVERLAY", sub and "GameFontHighlightSmall" or "GameFontNormal")
            b.text:SetPoint("LEFT", b, "RIGHT", 2, 0)
            b.text:SetText(text)
            return b
        end

        -- Grouped by zone, in the catalog's own order.
        local zones, order = {}, {}
        for _, entry in ipairs(GBA.HardList or {}) do
            if not zones[entry.zone] then zones[entry.zone] = {}; order[#order + 1] = entry.zone end
            table.insert(zones[entry.zone], entry)
        end

        local function report(ok, why)
            if not ok and why then GBA.Print("|cffff4040" .. tostring(why) .. "|r") end
        end

        for _, zone in ipairs(order) do
            local list = zones[zone]
            local header = box(y, 0, zoneName(zone) .. string.format("  |cff999999levels %d-%d|r",
                list[1].levels[1], list[1].levels[2]))
            header:SetScript("OnClick", function(self)
                local _, problem = ns.switchHardZone(zone, self:GetChecked() and true or false)
                report(problem == nil, problem)
                quests.refresh()
            end)
            boxes[#boxes + 1] = { button = header, zone = zone }
            y = y - 22
            for _, entry in ipairs(list) do
                local b = box(y, 18, entry.title .. "  |cff999999" .. asks(entry) .. " - " .. pays(entry) .. "|r", true)
                b:SetScript("OnClick", function(self)
                    report(ns.switchHard(entry.id, self:GetChecked() and true or false))
                    quests.refresh()
                end)
                b:SetMotionScriptsWhileDisabled(true)
                b:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(entry.title, 1, 1, 1)
                    GameTooltip:AddLine(entry.note or "", 0.8, 0.8, 0.8, true)
                    local held = ns.hardSwitch(entry.id)
                    if held then GameTooltip:AddLine("Switched on by " .. tostring(held.issuer), 0.4, 0.9, 0.4) end
                    GameTooltip:Show()
                end)
                b:SetScript("OnLeave", function() GameTooltip:Hide() end)
                boxes[#boxes + 1] = { button = b, id = entry.id }
                y = y - 18
            end
            y = y - 6
        end
        content:SetHeight(-y + 10)

        -- The boxes show what the guild has on, whoever ticked it; only an officer may change them.
        function quests.refresh()
            local officer = GBA.mayAct("offer")
            for _, b in ipairs(boxes) do
                if b.id then
                    b.button:SetChecked(ns.hardSwitch(b.id) ~= nil)
                else
                    local all = true
                    for _, entry in ipairs(zones[b.zone]) do
                        if not ns.hardSwitch(entry.id) then all = false; break end
                    end
                    b.button:SetChecked(all)
                end
                b.button:SetEnabled(officer)
            end
            note:SetText(officer and "" or "|cffff8040Officers switch guild quests on and off.|r")
        end

        quests:SetScript("OnShow", quests.refresh)
        quests:Hide()
        return quests
    end,
})

-- The guild's held sessions, in the session picker -------------------------------------------------

Analytics.addSource({
    key = "guild", label = "Guild", order = 2,
    list = function()
        local corpus = ns.corpus
        if not corpus then return {} end
        -- Busiest first: a guild's bot test holds hundreds of sessions, most of them a bot
        -- standing still, and the ones worth reading are the ones with fights in them.
        local out = {}
        local fight = GBA.Schema.factType.encounter
        for _, e in ipairs(corpus:episodesFor(nil)) do
            local episode = corpus.episodes[e.sessionID]
            local last, fights = 0, 0
            for _, row in ipairs(episode and episode.rows or {}) do
                local t = row.chain and row.chain.t or 0
                if t > last then last = t end
                if row.code == fight then fights = fights + 1 end
            end
            local who = tostring(e.observer or "?"):match("^([^%-]+)") or "?"
            out[#out + 1] = {
                id = e.sessionID, fights = fights, rows = e.rows,
                label = string.format("%s  %d fights, %d rows  %s  %d min", who, fights, e.rows,
                    date("%b %d %H:%M", e.sessionID), math.floor(last / 60 + 0.5)),
                episode = function() return corpus.episodes[e.sessionID] end,
                context = corpus.sessions[e.sessionID],
            }
        end
        table.sort(out, function(a, b)
            if a.fights ~= b.fights then return a.fights > b.fights end
            return a.rows > b.rows
        end)
        return out
    end,
})
