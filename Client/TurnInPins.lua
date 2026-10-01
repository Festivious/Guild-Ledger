-- Turn-in pins: the mailbox each accepted guild quest is turned in at, on the world map and the
-- minimap. Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 2.
--
-- One pin per mailbox, not per quest: a yellow question mark when something there is ready to
-- turn in, the way a quest giver shows it, and a grey one while the quests are still going. The
-- tooltip lists them. HereBeDragons-Pins places the pins (the library carries it, and MapView
-- plots sessions with it); our own handle means clearing these never touches anybody else's.
local _, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local HardList = GBA.HardList
local REF = "GuildLedgerTurnIns"
local ICON = "Interface\\GossipFrame\\ActiveQuestIcon"
local EVERY = 10

local function lib()
    local ok, pins = pcall(LibStub, "HereBeDragons-Pins-2.0", true)
    return ok and pins or nil
end

local pool = { world = {}, mini = {} }

local function pin(kind, index)
    local list = pool[kind]
    local p = list[index]
    if p then return p end
    p = CreateFrame("Frame", nil, UIParent)
    p:SetSize(kind == "world" and 18 or 14, kind == "world" and 18 or 14)
    p.texture = p:CreateTexture(nil, "OVERLAY")
    p.texture:SetTexture(ICON)
    p.texture:SetAllPoints()
    p:EnableMouse(true)
    p:SetScript("OnEnter", function(self)
        if not self.lines then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.place or "Guild quests", 1, 0.82, 0)
        for _, line in ipairs(self.lines) do GameTooltip:AddLine(line[1], line[2], line[3], line[4]) end
        GameTooltip:Show()
    end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list[index] = p
    return p
end

-- Rebuilds every pin from the quest log. Cheap: a handful of mailboxes at most.
function ns.refreshTurnInPins()
    local pins = lib()
    if not pins or not ns.guildQuestLog then return end
    pins:RemoveAllWorldMapIcons(REF)
    pins:RemoveAllMinimapIcons(REF)

    local ok, groups = pcall(ns.guildQuestLog)
    if not ok then return end

    -- Gathered by where they are turned in, which is not always where they were accepted.
    local byZone, order = {}, {}
    for _, group in ipairs(groups) do
        for _, row in ipairs(group.rows) do
            local zone = row.turnInZone
            if HardList.mailboxes and HardList.mailboxes[zone] then
                if not byZone[zone] then byZone[zone] = {}; order[#order + 1] = zone end
                table.insert(byZone[zone], row)
            end
        end
    end

    for index, zone in ipairs(order) do
        local box = HardList.mailboxes[zone]
        local ready, lines = false, {}
        for _, row in ipairs(byZone[zone]) do
            local done = row.progress and row.progress.done
            ready = ready or done
            lines[#lines + 1] = done and { row.entry.title .. " - ready", 0.45, 0.85, 0.45 }
                or { row.entry.title .. " - " .. ns.describeProgress(row), 0.9, 0.9, 0.9 }
        end
        for _, kind in ipairs({ "world", "mini" }) do
            local p = pin(kind, index)
            p.place, p.lines = box[3] .. " mailbox", lines
            if p.texture.SetDesaturated then p.texture:SetDesaturated(not ready) end
            if kind == "world" then
                pins:AddWorldMapIconMap(REF, p, zone, box[1] / 100, box[2] / 100)
            else
                pins:AddMinimapIconMap(REF, p, zone, box[1] / 100, box[2] / 100, false, true)
            end
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
    frame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    pcall(ns.refreshTurnInPins)
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(EVERY, function() pcall(ns.refreshTurnInPins) end)
    end
end)
