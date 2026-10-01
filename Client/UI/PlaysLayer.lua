-- The Plays layer: a session read as plays (CAT), in three steps.
--
--   zone    on the frame's map, with its art: every Questie camp (fence) outlined, the ones this
--           session's fields sit in lit, and a badge per place with how many plays happened there
--   field   a close-up of one place, a field or a path leg: its plays numbered in order, with the
--           walked route between
--   play    one play, step by step: the pull, the casts, the health, the kill, the loot; a fight
--           is read on the fight card (UI/FightCard.lua), blow by blow
--
-- The field and play steps are drawn on a plain close-up rather than the map: probed in game, the
-- map zooms only to about twice its widest view, where a whole field is some fifty pixels across.
-- Spec: docs/superpowers/specs/2026-09-26-cat-plays-design.md, 3.4 and 4.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Analytics = ns.Analytics
if not Analytics then return end

local Plays, Resolve = GBA.Plays, GBA.Resolve

local KIND = {
    fight  = { 1.00, 0.45, 0.35 },
    death  = { 1.00, 0.13, 0.13 },
    rest   = { 0.44, 0.63, 0.85 },
    gather = { 0.37, 0.83, 0.37 },
    town   = { 0.80, 0.60, 1.00 },
}
local STEP = {
    pull = { 1, 0.82, 0 }, kill = { 1, 0.45, 0.35 }, loot = { 1, 0.85, 0.4 }, skin = { 0.78, 0.66, 0.47 },
    gather = { 0.37, 0.83, 0.37 }, craft = { 0.37, 0.83, 0.83 }, death = { 1, 0.13, 0.13 },
    eat = { 0.44, 0.63, 0.85 }, drink = { 0.44, 0.63, 0.85 }, handin = { 0.8, 0.6, 1 }, accept = { 0.8, 0.6, 1 },
    abandon = { 0.8, 0.6, 1 }, level = { 0.45, 1, 0.45 }, skill = { 0.7, 0.9, 0.9 },
}
-- Steps with no place worth a pin of their own: they show in the list only.
local UNPLACED = { health = true, cast = true, xp = true, fightEnd = true, blow = true, aura = true, target = true }
local RESULT = { [1] = "crit", [2] = "miss", [3] = "dodged", [4] = "parried", [5] = "blocked", [6] = "resisted",
    [7] = "absorbed", [8] = "immune", [9] = "evaded" }

local SIDE = 176     -- the step list's width, at the play step
local BAR = 18       -- the bar along the bottom of the close-up

local state = { on = false, level = "zone", tab = "log" }
local names

-- Names, as Resolve gives them: from Questie and the client, the id when neither knows.
local function nm(kind, id)
    if id == nil then return "?" end
    names = names or Resolve.live(GBA.spokes)
    if kind == "npc" then return Resolve.npc(names, id) end
    if kind == "item" then return Resolve.item(names, id) end
    if kind == "spell" then return Resolve.spell(names, id) end
    if kind == "quest" then return Resolve.quest(names, id) end
    return kind .. " " .. tostring(id)
end

local function secs(s)
    s = s or 0
    if s >= 60 then return string.format("%d:%02d", math.floor(s / 60), s % 60) end
    return s .. " s"
end
local function clock(t)
    t = t or 0
    return string.format("%d:%02d into the session", math.floor(t / 60), t % 60)
end
local function hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end

local function headline(p)
    local mobs = {}
    for id, n in pairs(p.mobs or {}) do mobs[#mobs + 1] = nm("npc", id) .. (n > 1 and (" x" .. n) or "") end
    if p.kind == "fight" then
        local parts = { #mobs > 0 and table.concat(mobs, ", ") or "a fight", secs(p.seconds) }
        if p.low and p.low < 60 then parts[#parts + 1] = "health down to " .. p.low .. "%" end
        if p.died then parts[#parts + 1] = "died" end
        if p.xp and p.xp > 0 then parts[#parts + 1] = "+" .. p.xp .. " xp" end
        return table.concat(parts, " - ")
    elseif p.kind == "rest" then
        local made, item = 0, nil
        for _, s in ipairs(p.steps or {}) do if s.kind == "craft" then made = made + 1; item = s.item end end
        return "Rested " .. secs(p.seconds) .. (made > 0 and (" - made " .. made .. " " .. nm("item", item)) or "")
    elseif p.kind == "gather" then
        local items = {}
        for _, i in ipairs(p.items or {}) do items[#items + 1] = nm("item", i) end
        return "Picked " .. table.concat(items, ", ")
    elseif p.kind == "death" then
        return "Died to " .. (p.killer and nm("npc", p.killer) or "something") .. " - back in " .. secs(p.seconds)
    elseif p.kind == "town" then
        local handed, took = 0, 0
        for _, s in ipairs(p.steps or {}) do
            if s.kind == "handin" then handed = handed + 1 elseif s.kind == "accept" then took = took + 1 end
        end
        return "Town - handed in " .. handed .. ", took " .. took .. ((p.xp or 0) > 0 and (" - +" .. p.xp .. " xp") or "")
    end
    return p.kind
end

local function blowText(s)
    local how = RESULT[s.result]
    local spell = (s.spell and s.spell > 0) and nm("spell", s.spell) or "Melee"
    local amount = tostring(s.amount or 0)
    if s.dir == 1 then
        if how and s.result ~= 1 then return spell .. " " .. (s.result == 2 and "missed" or how) end
        return spell .. " hit for " .. amount .. (s.result == 1 and " (crit)" or "")
    elseif s.dir == 2 then
        local who = (s.npc and s.npc > 0) and nm("npc", s.npc) or "Something"
        if how and s.result ~= 1 then return who .. (s.result == 2 and " missed you" or (" - you " .. how)) end
        return who .. " hit you for " .. amount .. (s.result == 1 and " (crit)" or "")
    elseif s.dir == 4 then
        return spell .. " healed you for " .. amount
    end
    return spell .. " healed for " .. amount
end

local function stepText(s)
    local k = s.kind
    if k == "blow" then return blowText(s) end
    if k == "aura" then
        return (s.change == 2 and "Lost " or "Gained ") .. nm("spell", s.spell) .. (s.who == 2 and " (on target)" or "")
    end
    if k == "target" then return nm("npc", s.npc) .. " at " .. tostring(s.hp) .. "%" end
    if k == "pull" then return "Pulled " .. nm("npc", s.npc) end
    if k == "cast" then return nm("spell", s.spell) .. (s.npc and (" on " .. nm("npc", s.npc)) or "") end
    if k == "health" then return "Health " .. tostring(s.hp) .. "%" end
    if k == "kill" then return "Killed " .. nm("npc", s.npc) end
    if k == "xp" then return "+" .. tostring(s.amount) .. " experience" end
    if k == "loot" then return "Looted " .. nm("item", s.item) .. ((s.count or 1) > 1 and (" x" .. s.count) or "") end
    if k == "skin" then return "Skinned " .. nm("item", s.item) end
    if k == "gather" then return "Picked " .. nm("item", s.item) .. ((s.count or 1) > 1 and (" x" .. s.count) or "") end
    if k == "craft" then return "Made " .. nm("item", s.item) end
    if k == "eat" then return "Sat down to eat" end
    if k == "drink" then return "Sat down to drink" end
    if k == "death" then return "Died to " .. (s.npc and nm("npc", s.npc) or "something") end
    if k == "fightEnd" then return "Fight over after " .. tostring(s.seconds) .. " s" end
    if k == "handin" then return "Handed in " .. nm("quest", s.quest) end
    if k == "accept" then return "Took " .. nm("quest", s.quest) end
    if k == "abandon" then return "Abandoned " .. nm("quest", s.quest) end
    if k == "level" then return "Reached level " .. tostring(s.level) end
    if k == "skill" then return "Skill " .. tostring(s.skill) .. " reached " .. tostring(s.to) end
    return k
end

-- A fence's name: its commonest mob's grounds.
local function fenceName(mapID, id)
    local zone = GBA.Fields and GBA.Fields[mapID]
    for _, f in ipairs(zone and zone.fields or {}) do
        if f.id == id then
            local best, most
            for npc, n in pairs(f.mobs) do if not most or n > most then best, most = npc, n end end
            return best and (nm("npc", best) .. " grounds") or nil
        end
    end
    return nil
end

local function groupName(g)
    if g.name and g.name ~= "" then return g.open and (g.name .. " (path)") or g.name end
    if g.open then return "Path" end
    return (g.fence and fenceName(g.map, g.fence)) or ("Field " .. tostring(g.field))
end

-- "7 of 9 plays inside Kobold grounds", when the place touches a fence at all.
local function fenceLine(g)
    if not g.fence then return nil end
    return string.format("%d of %d plays inside %s", g.fenceInside or 0, #g.plays,
        fenceName(g.map, g.fence) or ("fence " .. g.fence))
end

-- Pools: frames and lines are made once and reused, as MapView's pins are ---------------------------

local function pool()
    return { lines = {}, lineUsed = 0, marks = {}, markUsed = 0 }
end
local onMap, onClose = pool(), pool()

local function release(p)
    for i = 1, #p.lines do p.lines[i]:Hide() end
    for i = 1, #p.marks do
        local m = p.marks[i]
        m:Hide(); m:SetScript("OnClick", nil); m.tip = nil
    end
    p.lineUsed, p.markUsed = 0, 0
end

local function line(p, parent, x1, y1, x2, y2, thick, r, g, b, a)
    p.lineUsed = p.lineUsed + 1
    local l = p.lines[p.lineUsed]
    if not l then
        l = parent:CreateLine(nil, "OVERLAY", nil, 2)
        p.lines[p.lineUsed] = l
    end
    l:SetColorTexture(r, g, b, a)
    l:SetThickness(thick)
    l:SetStartPoint("TOPLEFT", parent, x1, -y1)
    l:SetEndPoint("TOPLEFT", parent, x2, -y2)
    l:Show()
    return l
end

-- A square button with a number or a label in it, and a tooltip.
local function mark(p, parent, x, y, size, c, text, level)
    p.markUsed = p.markUsed + 1
    local m = p.marks[p.markUsed]
    if not m then
        m = CreateFrame("Button", nil, parent)
        m.edge = m:CreateTexture(nil, "BACKGROUND")
        m.edge:SetAllPoints()
        m.edge:SetColorTexture(0, 0, 0, 1)
        m.fill = m:CreateTexture(nil, "ARTWORK")
        m.fill:SetPoint("TOPLEFT", 1, -1)
        m.fill:SetPoint("BOTTOMRIGHT", -1, 1)
        m.text = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        m.text:SetPoint("CENTER")
        m.label = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        m.label:SetPoint("BOTTOM", m, "TOP", 0, 1)
        m:SetScript("OnEnter", function(self)
            if not self.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for i, l in ipairs(self.tip) do
                if i == 1 then GameTooltip:AddLine(l, 1, 1, 1) else GameTooltip:AddLine(l, 0.85, 0.85, 0.85, true) end
            end
            GameTooltip:Show()
        end)
        m:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p.marks[p.markUsed] = m
    end
    m:SetParent(parent)
    m:SetFrameLevel((parent:GetFrameLevel() or 0) + (level or 5))
    m:SetSize(size, size)
    m:ClearAllPoints()
    m:SetPoint("CENTER", parent, "TOPLEFT", x, -y)
    m.fill:SetColorTexture(c[1], c[2], c[3], 1)
    m.edge:SetColorTexture(0, 0, 0, 1)
    m.text:SetText(text or "")
    m.label:SetText("")
    m:Show()
    return m
end

-- The session, as plays ------------------------------------------------------------------------------

local function load(episode)
    state.plays, state.groups, state.byN = {}, {}, {}
    state.samples, state.whereMap = 0, nil
    if not episode or not episode.rows then return end
    -- Where the character was at all, for a session with no plays in it: many bots stand still.
    for _, row in ipairs(episode.rows) do
        if row.code == GBA.Schema.factType.position then
            state.samples = state.samples + 1
            local m = row.values and row.values.mapID
            if not state.whereMap and m and m > 0 then state.whereMap = m end
        end
    end
    local ok, plays = pcall(Plays.build, episode.rows, GBA.Fields)
    if not ok then
        if GBA.recordError then pcall(GBA.recordError, "plays: " .. tostring(plays), "") end
        return
    end
    state.plays = plays
    -- Distances in yards need each zone's size; HereBeDragons knows it.
    local hbd = LibStub and LibStub("HereBeDragons-2.0", true)
    local function sizeOf(mapID)
        if hbd and mapID then return hbd:GetZoneSize(mapID) end
    end
    state.groups = Plays.groups(plays, sizeOf)
    for _, p in ipairs(plays) do state.byN[p.n] = p end
end

local function groupsOn(mapID)
    local out = {}
    for _, g in ipairs(state.groups or {}) do if g.map == mapID then out[#out + 1] = g end end
    return out
end

local function firstMap()
    for _, p in ipairs(state.plays or {}) do if p.map and p.map > 0 then return p.map end end
    return state.whereMap
end

-- The close-up, built once over the map area ------------------------------------------------------------

local close

local function buildClose()
    local frame = Analytics.frame()
    close = CreateFrame("Frame", nil, frame.area, "BackdropTemplate")
    close:SetAllPoints(frame.area)
    close:SetFrameLevel((frame.area:GetFrameLevel() or 0) + 15)
    if close.SetBackdrop then
        close:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        close:SetBackdropColor(0.07, 0.08, 0.06, 0.97)
    end
    close:EnableMouse(true)

    close.view = CreateFrame("Frame", nil, close)
    close.view:SetClipsChildren(true)
    -- The wheel zooms the close-up in and out, up to twelve times closer than it opens.
    close.view:EnableMouseWheel(true)
    close.view:SetScript("OnMouseWheel", function(_, delta)
        state.zoom = math.max(1, math.min(12, (state.zoom or 1) * (delta > 0 and 1.4 or 1 / 1.4)))
        Analytics.drawPlays()
    end)

    close.side = CreateFrame("ScrollFrame", nil, close, "UIPanelScrollFrameTemplate")
    close.side:SetPoint("TOPRIGHT", close, "TOPRIGHT", -24, -4)
    close.side:SetPoint("BOTTOMRIGHT", close, "BOTTOMRIGHT", -24, BAR + 2)
    close.side:SetWidth(SIDE - 26)
    close.list = CreateFrame("Frame", nil, close.side)
    close.list:SetSize(SIDE - 26, 10)
    close.side:SetScrollChild(close.list)
    close.rows = {}

    local Card = ns.FightCard
    if Card then
        close.card = Card.build(close)
        close.card:SetPoint("TOPRIGHT", close, "TOPRIGHT", 0, 0)
        close.card:SetPoint("BOTTOMRIGHT", close, "BOTTOMRIGHT", 0, BAR)
        close.card:SetFrameLevel(close:GetFrameLevel() + 20)
    end

    close.bar = CreateFrame("Frame", nil, close)
    close.bar:SetPoint("BOTTOMLEFT", 0, 0)
    close.bar:SetPoint("BOTTOMRIGHT", 0, 0)
    close.bar:SetHeight(BAR)
    local bg = close.bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.8)
    close.buttons = {}
    local previous
    for _, spec in ipairs({ { "up", "Up" }, { "pplay", "<<" }, { "prev", "<" }, { "next", ">" }, { "nplay", ">>" }, { "open", "Open" } }) do
        local b = CreateFrame("Button", nil, close.bar, "UIPanelButtonTemplate")
        b:SetSize(spec[1] == "open" and 42 or (spec[1] == "up" and 32 or 26), BAR - 2)
        if previous then b:SetPoint("LEFT", previous, "RIGHT", 2, 0) else b:SetPoint("LEFT", close.bar, "LEFT", 2, 0) end
        b:SetText(spec[2])
        if b:GetFontString() then b:GetFontString():SetFontObject("GameFontHighlightSmall") end
        b:SetScript("OnClick", function() Analytics.playsAction(spec[1]) end)
        close.buttons[spec[1]] = b
        previous = b
    end
    close.where = close.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    close.where:SetPoint("LEFT", previous, "RIGHT", 6, 0)
    close.where:SetPoint("RIGHT", close.bar, "RIGHT", -4, 0)
    close.where:SetJustifyH("LEFT")
    close.where:SetWordWrap(false)
    close:Hide()
end

-- A view box around some map points, at the view's shape: returns a function from map space to the
-- view's pixels.
-- The close-up's ground: the minimap's own tiles, the ground seen from above, 256 pixels for
-- 533 1/3 yards. Tested in game (/gba minimaptest): they load as plain textures, and sit where the
-- plays happened. Placed through HereBeDragons' world yards, which it gives as (west-east,
-- north-south); a tile's column and row count from the middle of the world.
local TILE_YARDS = 1600 / 3
local CONTINENT = { [0] = "Azeroth", [1] = "Kalimdor" }
local ground = { list = {}, used = 0 }

local function drawGround(view, mapID, to, x0, y0, x1, y1)
    for i = 1, ground.used do ground.list[i]:Hide() end
    ground.used = 0
    local hbd = LibStub and LibStub("HereBeDragons-2.0", true)
    if not hbd or not mapID then return end
    local left, top, instance = hbd:GetWorldCoordinatesFromZone(0, 0, mapID)
    local right, bottom = hbd:GetWorldCoordinatesFromZone(1, 1, mapID)
    local dir = instance and CONTINENT[instance]
    if not left or not right or not dir then return end
    local width, height = left - right, top - bottom
    if width == 0 or height == 0 then return end

    -- Zone 0-1 space <-> tile numbers.
    local function tileAt(x, y)
        return 32 - (left - width * x) / TILE_YARDS, 32 - (top - height * y) / TILE_YARDS
    end
    local function zoneAt(col, row)
        return (left - (32 - col) * TILE_YARDS) / width, (top - (32 - row) * TILE_YARDS) / height
    end
    local c0, r0 = tileAt(x0, y0)
    local c1, r1 = tileAt(x1, y1)
    for col = math.floor(math.min(c0, c1)), math.floor(math.max(c0, c1)) do
        for row = math.floor(math.min(r0, r1)), math.floor(math.max(r0, r1)) do
            local zx0, zy0 = zoneAt(col, row)
            local zx1, zy1 = zoneAt(col + 1, row + 1)
            local px0, py0 = to(zx0, zy0)
            local px1, py1 = to(zx1, zy1)
            ground.used = ground.used + 1
            local t = ground.list[ground.used]
            if not t then
                t = view:CreateTexture(nil, "BACKGROUND")
                ground.list[ground.used] = t
            end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", view, "TOPLEFT", px0, -py0)
            t:SetSize(math.max(1, px1 - px0), math.max(1, py1 - py0))
            t:SetTexture(string.format("World\\Minimaps\\%s\\map%d_%d", dir, col, row))
            t:SetVertexColor(0.8, 0.8, 0.8)
            t:Show()
        end
    end
end

local function frameAround(points, minSize, vw, vh, zoom)
    local x0, y0, x1, y1 = 1, 1, 0, 0
    for _, p in ipairs(points) do
        if p[1] and p[2] then
            x0, y0 = math.min(x0, p[1]), math.min(y0, p[2])
            x1, y1 = math.max(x1, p[1]), math.max(y1, p[2])
        end
    end
    if x0 > x1 then x0, y0, x1, y1 = 0, 0, 1, 1 end
    -- Map space is a zone map, 1002 by 668 on the canvas; keep that shape so nothing is squashed.
    local cx, cy = (x0 + x1) / 2 * 1002, (y0 + y1) / 2 * 668
    local w = math.max((x1 - x0) * 1002 * 1.35, minSize * 1002)
    local h = math.max((y1 - y0) * 668 * 1.35, minSize * 1002 * vh / vw)
    if w / h > vw / vh then h = w * vh / vw else w = h * vw / vh end
    -- The mouse wheel's zoom, about the middle of what is shown.
    w, h = w / (zoom or 1), h / (zoom or 1)
    local left, top = cx - w / 2, cy - h / 2
    local k = vw / w
    return function(x, y) return (x * 1002 - left) * k, (y * 668 - top) * k end, k,
        left / 1002, top / 668, (left + w) / 1002, (top + h) / 668
end

local function hullPoints(f)
    local pts = {}
    for i = 1, #f.hull, 2 do pts[#pts + 1] = { f.hull[i], f.hull[i + 1] } end
    return pts
end

local function fieldOf(mapID, id)
    local zone = GBA.Fields and GBA.Fields[mapID]
    for _, f in ipairs(zone and zone.fields or {}) do if f.id == id then return f end end
    return nil
end

local function currentGroup()
    for _, g in ipairs(state.groups or {}) do if g.key == state.group then return g end end
    return nil
end

-- Drawing -------------------------------------------------------------------------------------------

local function drawZone()
    release(onMap)
    if not state.on then return end
    local canvas = Analytics.canvas()
    if not canvas then return end
    -- Drawn on the overlay above the map art; the surface itself sits under the art.
    local child = Analytics.overlay() or canvas:GetCanvas()
    local mapID = canvas:GetMapID()
    local W, H = child:GetWidth() or 0, child:GetHeight() or 0
    if W <= 0 or H <= 0 then return end
    local scale = (canvas.GetCanvasScale and canvas:GetCanvasScale()) or 1
    local function px(n) return n / scale end

    local groups = groupsOn(mapID)
    local played = {}
    for _, g in ipairs(groups) do if not g.open and g.fence then played[g.fence] = g end end

    local zone = GBA.Fields and GBA.Fields[mapID]
    for _, f in ipairs(zone and zone.fields or {}) do
        local lit = played[f.id] ~= nil
        local pts = hullPoints(f)
        for i = 1, #pts do
            local a, b = pts[i], pts[i % #pts + 1]
            line(onMap, child, a[1] * W, a[2] * H, b[1] * W, b[2] * H, px(lit and 2 or 1), 1, 0.82, 0, lit and 0.9 or 0.3)
        end
    end

    for _, g in ipairs(groups) do
        local x, y = g.x, g.y
        local m = mark(onMap, child, x * W, y * H, px(18), g.open and { 0.2, 0.3, 0.45 } or { 0.25, 0.2, 0.05 }, tostring(#g.plays), 50)
        m.edge:SetColorTexture(g.open and 0.62 or 1, g.open and 0.82 or 0.82, g.open and 1 or 0, 1)
        if #g.plays >= 3 then m.label:SetText(groupName(g)) end
        local kinds = {}
        for kind, count in pairs(g.kinds) do kinds[#kinds + 1] = count .. " " .. kind .. (count > 1 and "s" or "") end
        m.tip = { groupName(g), #g.plays .. " plays: " .. table.concat(kinds, ", ") .. " - " .. secs(g.seconds) }
        local fl = fenceLine(g)
        if fl then m.tip[#m.tip + 1] = fl end
        m.tip[#m.tip + 1] = g.open and "A path: plays on the way between fields. Click to see them."
            or "A field: fights close together. Click to see its plays."
        m:SetScript("OnClick", function()
            GameTooltip:Hide()
            state.level, state.group, state.play, state.step = "field", g.key, g.plays[1], 1
            Analytics.drawPlays()
        end)
    end

    local count = #(state.plays or {})
    if count == 0 then
        Analytics.setTitle(string.format("No plays |cff999999- %d position samples, nothing fought, gathered or handed in|r",
            state.samples or 0))
    else
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
        Analytics.setTitle((info and info.name or "") .. "  |cff999999" .. #groups .. " places, " .. count .. " plays|r")
    end
end

local function drawClose()
    release(onClose)
    local g = currentGroup()
    local p = state.play and state.byN[state.play]
    if not g or not p then state.level = "zone"; close:Hide(); return drawZone() end
    close:Show()

    local playing = state.level == "play"
    -- A fight is read on the fight card, the rest on the step list.
    local carded = playing and p.kind == "fight" and close.card ~= nil
    local vw = (close:GetWidth() or 468) - (carded and ns.FightCard.WIDTH or (playing and SIDE or 0))
    local vh = (close:GetHeight() or 306) - BAR
    close.view:ClearAllPoints()
    close.view:SetPoint("TOPLEFT", close, "TOPLEFT", 0, 0)
    close.view:SetSize(vw, vh)
    close.side:SetShown(playing and not carded)
    if close.card then close.card:SetShown(carded) end

    local points = {}
    if playing then
        points[#points + 1] = { p.x, p.y }
        for _, q in ipairs(p.path or {}) do points[#points + 1] = { q.x, q.y } end
        for _, s in ipairs(p.steps or {}) do if s.x then points[#points + 1] = { s.x, s.y } end end
    else
        for _, n in ipairs(g.plays) do local q = state.byN[n]; points[#points + 1] = { q.x, q.y } end
    end
    -- A new place or a new play opens unzoomed.
    local key = state.level .. ":" .. tostring(state.group) .. ":" .. (playing and tostring(state.play) or "")
    if key ~= state.zoomKey then state.zoom, state.zoomKey = 1, key end
    local to, _, vx0, vy0, vx1, vy1 = frameAround(points, playing and 0.035 or 0.06, vw, vh, state.zoom)
    local view = close.view
    local okGround, groundErr = pcall(drawGround, view, g.map, to, vx0, vy0, vx1, vy1)
    if not okGround and GBA.recordError then pcall(GBA.recordError, "plays ground: " .. tostring(groundErr), "") end

    -- The fence the place sits in, when there is one.
    local f = g.fence and fieldOf(g.map, g.fence)
    if f then
        local pts = hullPoints(f)
        for i = 1, #pts do
            local a, b = pts[i], pts[i % #pts + 1]
            local ax, ay = to(a[1], a[2])
            local bx, by = to(b[1], b[2])
            line(onClose, view, ax, ay, bx, by, 1.5, 1, 0.82, 0, 0.6)
        end
    end

    local function route(path, r, gg, b, a, thick)
        for i = 2, #(path or {}) do
            local q1, q2 = path[i - 1], path[i]
            if q1.map == q2.map then
                local ax, ay = to(q1.x, q1.y)
                local bx, by = to(q2.x, q2.y)
                line(onClose, view, ax, ay, bx, by, thick, r, gg, b, a)
            end
        end
    end

    if not playing then
        -- The play sheet: the routes, then the plays numbered in order.
        for i, n in ipairs(g.plays) do
            local q = state.byN[n]
            local fromHere = i > 1 and g.plays[i - 1] == n - 1
            if q.route then route(q.route.path, 0.91, 0.88, 0.75, fromHere and 0.8 or 0.3, 1.5) end
        end
        for i, n in ipairs(g.plays) do
            local q = state.byN[n]
            local x, y = to(q.x, q.y)
            local on = n == state.play
            local m = mark(onClose, view, x, y, on and 18 or 15, KIND[q.kind] or { 1, 1, 1 }, tostring(i), on and 8 or 5)
            if on then m.edge:SetColorTexture(1, 1, 1, 1) end
            m.tip = { i .. ". " .. q.kind, headline(q), clock(q.t0) .. (q.subzone ~= "" and (" - " .. q.subzone) or "") }
            if q.route then m.tip[#m.tip + 1] = "walked here in " .. secs(q.route.seconds) end
            for _, b in ipairs(q.badges or {}) do
                m.tip[#m.tip + 1] = b.kind == "level" and ("Reached level " .. b.level) or ("Skill " .. b.skill .. " reached " .. b.to)
            end
            m:SetScript("OnClick", function()
                GameTooltip:Hide()
                state.play, state.level, state.step = n, "play", 1
                Analytics.drawPlays()
            end)
        end
    else
        -- One play: the way in, the path during it, and a pin per step that has a place.
        if p.route then route(p.route.path, 0.91, 0.88, 0.75, 0.3, 1.2) end
        route(p.path, 0.63, 0.86, 0.67, 0.9, 2)
        local steps = p.steps or {}
        local cur = steps[state.step]
        for i, s in ipairs(steps) do
            if s.x and not UNPLACED[s.kind] then
                local x, y = to(s.x, s.y)
                local on = i == state.step
                local m = mark(onClose, view, x, y, on and 13 or 9, STEP[s.kind] or { 0.8, 0.8, 0.8 }, "", on and 8 or 5)
                if on then m.edge:SetColorTexture(1, 1, 1, 1) end
                m.tip = { s.t .. " s", stepText(s) }
                m:SetScript("OnClick", function() state.step = i; Analytics.drawPlays() end)
            end
        end
        if cur and cur.x and carded then
            -- The character at the chosen moment: a dot, and a line the way they faced.
            local x, y = to(cur.x, cur.y)
            if cur.facing then
                local a = math.rad(cur.facing)
                line(onClose, view, x, y, x + math.cos(a) * 13, y + math.sin(a) * 13, 2, 1, 1, 1, 0.95)
            end
            local m = mark(onClose, view, x, y, 9, cur.moving and { 0.62, 0.82, 1 } or { 1, 1, 1 }, "", 9)
            m.tip = { cur.t .. " s", stepText(cur) }
        elseif cur and cur.x and UNPLACED[cur.kind] then
            local x, y = to(cur.x, cur.y)
            local m = mark(onClose, view, x, y, 11, { 1, 1, 1 }, "", 8)
            m.fill:SetColorTexture(0, 0, 0, 0)
            m.edge:SetColorTexture(1, 1, 1, 0.9)
        end

        if carded then
            local session = Analytics.session()
            ns.FightCard.draw(close.card, p, state.step, {
                nm = nm, stepText = stepText, headline = headline, clock = clock,
                colour = function(kind) return STEP[kind] or { 0.87, 0.87, 0.87 } end,
                setStep = function(i) state.step = i; Analytics.drawPlays() end,
                tab = state.tab,
                setTab = function(key) state.tab = key; Analytics.drawPlays() end,
                context = session and session.context,
                height = vh,
            })
        end

        -- The list, with the health at the chosen step.
        if carded then steps = {} end
        local hp
        for i = 1, math.min(state.step, #steps) do if steps[i].kind == "health" then hp = steps[i].hp end end
        local lines = { { text = "|cffffd100" .. headline(p) .. "|r", head = true },
            { text = "|cff999999" .. clock(p.t0) .. (p.subzone ~= "" and (" - " .. p.subzone) or "") .. "|r", head = true } }
        if hp then lines[#lines + 1] = { text = string.format("Health %d%%", hp), head = true, hp = hp } end
        for i, s in ipairs(steps) do
            local dim = s.kind == "health" or s.kind == "cast"
            local c = dim and "|cff7a7a7a" or hex(STEP[s.kind] or { 0.9, 0.9, 0.9 })
            lines[#lines + 1] = { text = string.format("|cff777777%3ds|r  %s%s|r", s.t, c, stepText(s)), index = i }
        end
        local y = 0
        for i, l in ipairs(lines) do
            local row = close.rows[i]
            if not row then
                row = CreateFrame("Button", nil, close.list)
                row:SetHeight(12)
                row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.text:SetPoint("LEFT", 2, 0)
                row.text:SetPoint("RIGHT", -2, 0)
                row.text:SetJustifyH("LEFT")
                row.text:SetWordWrap(false)
                row.on = row:CreateTexture(nil, "BACKGROUND")
                row.on:SetAllPoints()
                row.on:SetColorTexture(0.35, 0.28, 0.08, 0.8)
                row.hp = row:CreateTexture(nil, "ARTWORK")
                row.hp:SetPoint("LEFT", 2, 0)
                row.hp:SetHeight(3)
                row.hp:SetPoint("BOTTOM", 0, 0)
                close.rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", close.list, "TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", close.list, "RIGHT", 0, 0)
            row.text:SetText(l.text)
            row.on:SetShown(l.index == state.step)
            if l.hp then
                row.hp:SetColorTexture(0.2, 0.8, 0.2, 1)
                row.hp:SetWidth(math.max(1, (SIDE - 32) * l.hp / 100))
                row.hp:Show()
            else row.hp:Hide() end
            row:SetScript("OnClick", l.index and function() state.step = l.index; Analytics.drawPlays() end or nil)
            row:Show()
            y = y + 12
        end
        for i = #lines + 1, #close.rows do close.rows[i]:Hide() end
        close.list:SetHeight(y + 4)
    end

    -- The bar: where, and what the buttons can do from here.
    local i = 0
    for k, n in ipairs(g.plays) do if n == state.play then i = k end end
    local b = close.buttons
    b.pplay:SetEnabled(playing and i > 1)
    b.nplay:SetEnabled(playing and i < #g.plays)
    b.open:SetShown(not playing)
    b.pplay:SetShown(playing)
    b.nplay:SetShown(playing)
    if playing then
        local steps = p.steps or {}
        b.prev:SetEnabled(state.step > 1)
        b.next:SetEnabled(state.step < #steps)
        close.where:SetText(string.format("step %d of %d: %s", state.step, #steps, steps[state.step] and stepText(steps[state.step]) or ""))
        Analytics.setTitle(groupName(g) .. "  >  " .. i .. ". " .. p.kind)
    else
        b.prev:SetEnabled(i > 1)
        b.next:SetEnabled(i < #g.plays)
        close.where:SetText(string.format("play %d of %d: %s", i, #g.plays, headline(p)))
        Analytics.setTitle(groupName(g) .. "  |cff999999" .. #g.plays .. " plays|r")
    end
end

function Analytics.drawPlays()
    if not state.on then return end
    if not close then buildClose() end
    names = nil
    if state.level == "zone" then
        close:Hide()
        drawZone()
    else
        release(onMap)
        drawClose()
    end
end

function Analytics.playsAction(action)
    local g = currentGroup()
    if not g then return end
    local i = 0
    for k, n in ipairs(g.plays) do if n == state.play then i = k end end
    if action == "up" then
        if state.level == "play" then state.level = "field" else state.level, state.group = "zone", nil end
    elseif action == "open" then
        state.level, state.step = "play", 1
    elseif state.level == "field" then
        if action == "prev" and i > 1 then state.play = g.plays[i - 1] end
        if action == "next" and i < #g.plays then state.play = g.plays[i + 1] end
    elseif state.level == "play" then
        local steps = (state.byN[state.play] or {}).steps or {}
        if action == "prev" and state.step > 1 then state.step = state.step - 1 end
        if action == "next" and state.step < #steps then state.step = state.step + 1 end
        if action == "pplay" and i > 1 then state.play, state.step = g.plays[i - 1], 1 end
        if action == "nplay" and i < #g.plays then state.play, state.step = g.plays[i + 1], 1 end
    end
    Analytics.drawPlays()
end

-- The layer ----------------------------------------------------------------------------------------------

local function showSession()
    state.level, state.group, state.play, state.step = "zone", nil, nil, 1
    -- A session with nothing to draw (a /reload) still shows a map: where the player is now.
    local mapID = firstMap() or (Analytics.playerMap and Analytics.playerMap())
    local canvas = Analytics.canvas()
    if mapID and canvas and canvas:GetMapID() ~= mapID then
        Analytics.showMap(mapID)       -- onMapReady draws once the map has taken
    else
        Analytics.drawPlays()
    end
end

-- Redrawn whenever the map settles on a zone: a session opened, or the player clicked in or out.
Analytics.onMapReady = function()
    if state.on and state.level == "zone" then drawZone() end
end

Analytics.addLayer({
    key = "plays", label = "Plays", order = 5,
    onShow = function()
        state.on = true
        local session = Analytics.session()
        if not session then
            if not Analytics.pickNewest() then Analytics.setTitle("No sessions recorded yet") end
            return   -- choosing calls onSession, which draws
        end
        if not state.plays then load(session.episode) end
        showSession()
    end,
    onHide = function()
        state.on = false
        release(onMap)
        release(onClose)
        if close then close:Hide() end
    end,
    onSession = function(session)
        load(session and session.episode)
        if state.on then showSession() end
    end,
})

-- The marks on the map keep their size on screen as the map zooms.
local hooked
local function hookZoom()
    local canvas = Analytics.canvas()
    if hooked or not canvas or not canvas.OnCanvasScaleChanged then return end
    hooked = true
    hooksecurefunc(canvas, "OnCanvasScaleChanged", function()
        if state.on and state.level == "zone" then drawZone() end
    end)
end
local previousReady = Analytics.onMapReady
Analytics.onMapReady = function(mapID)
    hookZoom()
    previousReady(mapID)
end
