-- The analytics frame: our own map, with a session's story drawn on top of it.
--
-- Everyone has it. A member reads their own sessions, straight from this character's capture
-- buffer: nothing is sent to show it. The Guild addon carries this file (Client/Client.xml) and
-- adds to the same frame through two small hooks instead of building its own:
--
--   Analytics.addLayer(layer)    a side tab and its drawer (Vault, Quests, the officer views), or
--                                a drawing that is always on (Plays)
--   Analytics.addSource(source)  another list of sessions for the picker (the guild's)
--
-- Both are only read when the frame is first opened, so a file loaded later can still register.
-- Spec: docs/superpowers/specs/2026-09-26-cat-plays-design.md, 3.5.
--
-- Small on purpose. The game is what the player came to look at; this opens from a key binding
-- (Key Bindings > AddOns > GuildLedger) or the Guild Quest Log's button, closes with Escape, and
-- leaves the rest of the screen alone. If the map cannot be built, the frame still opens, says
-- so, and records why with the addon's other errors.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema = GBA.Schema

local Analytics = {}
ns.Analytics = Analytics

local WIDTH, HEIGHT = 480, 360
-- The row of checkboxes that sat under the title is gone (2026-09-29): the frame opens into a
-- session, and panels have side tabs. Kept at 0 so the map starts right under the title.
local STRIP = 0
local DOT_EVERY = 0.2
local PICK_ROWS = 20          -- rows shown at once; the mouse wheel scrolls the rest

local frame, canvas, dot, picker
-- Frames stacked over the map surface. Textures drawn on the surface itself sit under the map
-- art, whose layers are frames of their own; Blizzard's pins are frames above it for the same
-- reason. fogLayer holds the explored overlays just above the art; overlay is above that, for
-- everything drawn on the map (the player's arrow, the hover glow, the layers' marks).
local fogLayer, overlay
local layers, sources = {}, {}
local chosen            -- { source, id, label, episode }

-- Registration ----------------------------------------------------------------------------------

-- layer: { key, label, order, build = function(frame, area) -> panel, onShow, onHide, onSession,
--          icon, hint, drawerWidth }
-- A layer with build gets a side tab and a drawer beside the frame (DEC-17: nothing covers the
-- map); area is the drawer's inside. A layer without one is always on: its onShow runs when the
-- frame first opens, and it draws on the map (the Plays layer).
function Analytics.addLayer(layer)
    layers[#layers + 1] = layer
end

-- source: { key, label, order, list = function() -> { { id, label, episode = function() } } }
function Analytics.addSource(source)
    sources[#sources + 1] = source
end

-- The session the picker is on: { source, id, label, episode }, or nil.
function Analytics.session()
    return chosen
end

-- Everything the map frame offers the layers.
function Analytics.frame() return frame end
-- Every overlay of a map, explored or not (LibGuildLedger/MapReveal.lua, from Blizzard's own
-- tables): this is our map, so the whole zone shows. The world map is left as it is.
function Analytics.revealed(mapID)
    local list = GBA.MapReveal and GBA.MapReveal[mapID]
    local out = {}
    for i, o in ipairs(list or {}) do
        out[i] = { textureWidth = o[1], textureHeight = o[2], offsetX = o[3], offsetY = o[4], fileDataIDs = o[5] }
    end
    return out
end

-- The frame to draw map marks on: the map surface's size, above the art.
function Analytics.overlay() return overlay end
function Analytics.canvas() return canvas end

-- "Mine": this character's sessions, from the capture buffer ----------------------------------

-- The buffer's rows for one session, in the shape the guild's held episodes have
-- ({ code, values, chain }), so every layer reads both the same way.
local function myEpisode(sessionID)
    local rows = {}
    -- From the pool or the archive, wherever the session is now (Archive.lua).
    local source = ns.sessionRecords and ns.sessionRecords(sessionID) or (ns.buffer and ns.buffer.entries) or {}
    for _, entry in ipairs(source) do
        if entry.sessionID == sessionID then
            rows[#rows + 1] = {
                code = entry.code,
                values = Schema.fromArray(entry.code, entry.values) or {},
                chain = { sessionID = entry.sessionID, legID = entry.legID, encounterID = entry.encounterID,
                          groupID = entry.groupID, t = entry.t, seq = entry.seq },
            }
        end
    end
    return { sessionID = sessionID, observer = UnitName("player"), rows = rows }
end

local function sessionLabel(sessionID, seconds, rows)
    return string.format("%s  %d min, %d rows", date("%b %d %H:%M", sessionID),
        math.floor((seconds or 0) / 60 + 0.5), rows or 0)
end

Analytics.addSource({
    key = "mine", label = "Mine", order = 1,
    list = function()
        local bySession, order = {}, {}
        for _, entry in ipairs(ns.buffer and ns.buffer.entries or {}) do
            local sid = entry.sessionID
            if sid then
                local s = bySession[sid]
                if not s then s = { rows = 0, last = 0 }; bySession[sid] = s; order[#order + 1] = sid end
                s.rows = s.rows + 1
                if (entry.t or 0) > s.last then s.last = entry.t end
            end
        end
        -- Sessions that left the pool are archived, locked with this character's own key
        -- (docs/fix-plan.md, DEC-19): listed from the archive's own summary, and not viewable
        -- until unlocked, which puts them back in the pool.
        local archivedLabel = {}
        for _, a in ipairs(ns.Archive and ns.Archive.list() or {}) do
            if not bySession[a.sessionID] then
                bySession[a.sessionID] = { rows = a.rows or 0, last = (a.last or a.sessionID) - a.sessionID }
                order[#order + 1] = a.sessionID
                archivedLabel[a.sessionID] = true
            end
        end
        table.sort(order, function(a, b) return a > b end)
        local out = {}
        for _, sid in ipairs(order) do
            local s = bySession[sid]
            local locked = archivedLabel[sid] == true
            out[#out + 1] = { id = sid, rows = s.rows, locked = locked,
                label = sessionLabel(sid, s.last, s.rows) .. (locked and "  |cff999999(archived, locked)|r" or ""),
                episode = function() return myEpisode(sid) end, context = ns.sessions and ns.sessions[sid],
                -- Picking a locked one asks to unlock it; it opens once back in the pool.
                onChoose = locked and function()
                    local dialog = StaticPopup_Show("GUILDLEDGER_UNLOCK_SESSION", sessionLabel(sid, s.last, s.rows))
                    if dialog then dialog.data = sid end
                end or nil }
        end
        return out
    end,
})

-- The frame ------------------------------------------------------------------------------------

local function note(text)
    frame.note:SetText(text or "")
    frame.note:SetShown(text ~= nil)
end

local function failed(what, err)
    local msg = "analytics map: " .. what .. ": " .. tostring(err)
    if GBA.recordError then pcall(GBA.recordError, msg, "") end
    note("The map could not be built on this client.\n" .. tostring(err))
end

-- The zone the player is in, or the nearest map above it that the client can name.
local function playerMap()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    return C_Map.GetBestMapForUnit("player")
end

-- The scroll container holds the surface's size and the zoom levels, and the canvas does not
-- reliably pass its map down to it. Probed in game: on a first open it had none, later it still
-- held the previous zone, and handing it the map the instant the frame opened failed quietly
-- (the frame had no size yet). With no zoom levels, its own per-frame update fails every frame
-- (1388 errors in one sitting). So it stays hidden until it has the map and its zoom levels, and
-- the map is handed over again a moment later until it takes, for about a second.
local READY_TRIES, READY_EVERY = 20, 0.05

local function scrollReady(scroll, mapID)
    return scroll.mapID == mapID and type(scroll.zoomLevels) == "table" and #scroll.zoomLevels > 0
end

-- The art (the painted map) is the canvas's detail layers. It redraws them only when it has
-- marked them dirty itself, and in game the frame stayed a dark box with none drawn, so an empty
-- set is marked dirty before asking.
-- The explored parts of the map: on the world map another of Blizzard's providers paints them
-- over the base art, and without it every zone looked unexplored. Drawn here from the same call
-- that provider uses, tiled the way it tiles them. Analytics.revealed, when set, adds overlays
-- for the parts this character has not explored (see MapReveal.lua).
local fog = {}

local function tile(list, used, child, info, tileW, tileH, layer)
    local wide = math.ceil(info.textureWidth / tileW)
    local tall = math.ceil(info.textureHeight / tileH)
    for j = 1, tall do
        local pixelH, fileH = tileH, tileH
        if j == tall then
            pixelH = info.textureHeight % tileH
            if pixelH == 0 then pixelH = tileH end
            fileH = 16
            while fileH < pixelH do fileH = fileH * 2 end
        end
        for k = 1, wide do
            local pixelW, fileW = tileW, tileW
            if k == wide then
                pixelW = info.textureWidth % tileW
                if pixelW == 0 then pixelW = tileW end
                fileW = 16
                while fileW < pixelW do fileW = fileW * 2 end
            end
            local file = info.fileDataIDs[(j - 1) * wide + k]
            if file then
                used = used + 1
                local t = list[used]
                if not t then t = child:CreateTexture(nil, "ARTWORK", nil, layer); list[used] = t end
                t:ClearAllPoints()
                t:SetSize(pixelW, pixelH)
                t:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
                t:SetPoint("TOPLEFT", child, "TOPLEFT", info.offsetX + tileW * (k - 1), -(info.offsetY + tileH * (j - 1)))
                t:SetTexture(file)
                t:Show()
            end
        end
    end
    return used
end

local function drawExplored(mapID)
    local child = fogLayer
    for _, t in ipairs(fog) do t:Hide() end
    local layers = C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(mapID)
    local layer = layers and layers[1]
    if not layer or not layer.tileWidth then return end
    local used = 0
    local explored = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
        and C_MapExplorationInfo.GetExploredMapTextures(mapID) or {}
    local seen = {}
    for _, info in ipairs(explored) do
        used = tile(fog, used, child, info, layer.tileWidth, layer.tileHeight, 1)
        seen[info.offsetX .. ":" .. info.offsetY] = true
    end
    for _, info in ipairs(Analytics.revealed and Analytics.revealed(mapID) or {}) do
        if not seen[info.offsetX .. ":" .. info.offsetY] then
            used = tile(fog, used, child, info, layer.tileWidth, layer.tileHeight, 0)
        end
    end
end

local function drawArt()
    local pool = canvas.detailLayerPool
    if pool and pool.GetNumActive and pool:GetNumActive() == 0 then canvas.areDetailLayersDirty = true end
    if canvas.RefreshDetailLayers then pcall(canvas.RefreshDetailLayers, canvas) end
    local ok, err = pcall(drawExplored, canvas:GetMapID())
    if not ok and GBA.recordError then pcall(GBA.recordError, "analytics map explored: " .. tostring(err), "") end
end

local wanted   -- the map most recently asked for; an older retry gives way to it

local function settle(mapID, tries)
    if not canvas or wanted ~= mapID then return end
    local scroll = canvas.ScrollContainer
    if not scroll then return end
    if not scrollReady(scroll, mapID) and (scroll:GetWidth() or 0) > 0 and scroll.SetMapID then
        local ok, err = pcall(scroll.SetMapID, scroll, mapID)
        if not ok then scroll.gbaLastError = tostring(err) end
    end
    if scrollReady(scroll, mapID) then
        scroll:Show()
        drawArt()
        if Analytics.onMapReady then pcall(Analytics.onMapReady, mapID) end
        return
    end
    if tries > 0 and C_Timer and C_Timer.After then
        C_Timer.After(READY_EVERY, function() settle(mapID, tries - 1) end)
    elseif GBA.recordError then
        pcall(GBA.recordError, "analytics map: no zoom levels for map " .. tostring(mapID) ..
            " (width " .. tostring(scroll:GetWidth()) .. ") " .. tostring(scroll.gbaLastError or ""), "")
    end
end

function Analytics.showMap(mapID)
    if not canvas or not mapID then return end
    local ok, err = pcall(canvas.SetMapID, canvas, mapID)
    if not ok then return failed("SetMapID", err) end
    wanted = mapID
    local scroll = canvas.ScrollContainer
    if scroll and not scrollReady(scroll, mapID) then scroll:Hide() end
    settle(mapID, READY_TRIES)
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    Analytics.setTitle(info and info.name or ("map " .. mapID))
end

-- The cursor's place on the map, 0-1 across and down, from the drawn surface's own edges and
-- scale on screen; nil when the cursor is off it or the surface has no size yet.
function Analytics.cursorOnMap()
    local child = canvas and canvas:GetCanvas()
    if not child then return nil end
    local left, top, w, h = child:GetLeft(), child:GetTop(), child:GetWidth(), child:GetHeight()
    local scale = child:GetEffectiveScale()
    if not left or not top or not w or w <= 0 or h <= 0 or not scale or scale <= 0 then return nil end
    local x, y = GetCursorPosition()
    local nx, ny = (x / scale - left) / w, (top - y / scale) / h
    if nx < 0 or nx > 1 or ny < 0 or ny > 1 then return nil end
    return nx, ny
end

function Analytics.setTitle(text)
    if frame then frame.title:SetText(text or "") end
end

-- Right-click steps out: zone, then continent, then the world.
local function stepOut()
    local id = canvas and canvas:GetMapID()
    local info = id and C_Map.GetMapInfo(id)
    if info and info.parentMapID and info.parentMapID > 0 then Analytics.showMap(info.parentMapID) end
end

-- The player's dot, placed by the coordinate the client reports for this map.
-- Hover: the zone under the cursor lit, as the world map lights it, and named in a tooltip.
-- C_Map.GetMapHighlightInfoAtPosition is the call Blizzard's own highlight pin draws from; the
-- position is ours (Analytics.cursorOnMap), measured against the drawn surface.
local glow, hovered, hoverBroken
local HOVER_EVERY = 0.05

local function clearHover()
    if glow then glow:Hide() end
    if hovered then hovered = nil; GameTooltip:Hide() end
end

local function hover()
    local scroll = canvas and canvas.ScrollContainer
    if not scroll or not scroll:IsShown() or not scroll:IsMouseOver() then return clearHover() end
    local current = canvas:GetMapID()
    local cx, cy = Analytics.cursorOnMap()
    local info = cx and current and C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(current, cx, cy)
    if not info or not info.mapID or info.mapID == current then return clearHover() end

    local child = canvas:GetCanvas()
    if not glow then
        glow = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
        glow:SetBlendMode("ADD")
    end
    local w, h = child:GetWidth(), child:GetHeight()
    local ok, fileID, atlasID, tx, ty, sizeX, sizeY, posX, posY = pcall(C_Map.GetMapHighlightInfoAtPosition, current, cx, cy)
    glow:ClearAllPoints()
    if ok and atlasID then
        glow:SetAtlas(atlasID, true)
        glow:SetTexCoord(0, tx or 1, 0, ty or 1)
        glow:SetPoint("CENTER", child, "CENTER", ((posX + 0.5 * sizeX) - 0.5) * w, -((posY + 0.5 * sizeY) - 0.5) * h)
        glow:Show()
    elseif ok and fileID and fileID > 0 and sizeX and sizeX > 0 then
        glow:SetTexture(fileID)
        glow:SetTexCoord(0, tx or 1, 0, ty or 1)
        glow:SetSize(sizeX * w, sizeY * h)
        glow:SetPoint("TOPLEFT", child, "TOPLEFT", posX * w, -posY * h)
        glow:Show()
    else
        glow:Hide()
    end

    if hovered ~= info.mapID then
        hovered = info.mapID
        GameTooltip:SetOwner(scroll, "ANCHOR_CURSOR")
        GameTooltip:AddLine(info.name or ("map " .. info.mapID), 1, 1, 1)
        local okLevels, low, high = pcall(C_Map.GetMapLevels or error, info.mapID)
        if okLevels and low and high and low > 0 then
            GameTooltip:AddLine(low == high and ("Level " .. low) or ("Levels " .. low .. "-" .. high), 1, 0.82, 0)
        end
        GameTooltip:AddLine("Click to open", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
end

local function placeDot()
    if not canvas or not dot then return end
    local id = canvas:GetMapID()
    local pos = id and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(id, "player")
    local child = canvas:GetCanvas()
    if not pos or not child then dot:Hide(); return end
    local x, y = pos:GetXY()
    if not x or x <= 0 or y <= 0 or x >= 1 or y >= 1 then dot:Hide(); return end
    dot:ClearAllPoints()
    dot:SetPoint("CENTER", child, "TOPLEFT", x * child:GetWidth(), -y * child:GetHeight())
    dot:Show()
end

local function buildCanvas()
    if not MapCanvasMixin and C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "Blizzard_MapCanvas")
    end
    if not MapCanvasMixin or not Mixin then
        return failed("MapCanvasMixin", "this client has no map canvas to build on")
    end

    -- Built the way the Zone Map (BattlefieldMapFrame) is: MapCanvasFrameTemplate expects a
    -- ScrollContainer child that its OnLoad reaches for straight away, so the child is made
    -- first and the canvas behaviour mixed in and started after it.
    local made = CreateFrame("Frame", "GuildLedgerAnalyticsMap", frame)
    made:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(STRIP + 26))
    made:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
    local okScroll, scroll = pcall(CreateFrame, "ScrollFrame", nil, made, "MapCanvasFrameScrollContainerTemplate")
    if not okScroll or not scroll then return failed("MapCanvasFrameScrollContainerTemplate", scroll) end
    scroll:SetAllPoints(made)
    made.ScrollContainer = scroll
    -- The other child Blizzard's map frames declare and the canvas reaches for: without it,
    -- drawing the map failed in game on "attempt to index field 'BorderFrame' (a nil value)"
    -- (Blizzard_MapCanvas.lua:735). Ours is plain; the canvas only needs it to exist, above
    -- the map.
    local border = CreateFrame("Frame", nil, made)
    border:SetAllPoints(made)
    border:SetFrameLevel((made:GetFrameLevel() or 0) + 10)
    made.BorderFrame = border

    Mixin(made, MapCanvasMixin)
    local okLoad, loadErr = pcall(made.OnLoad, made)
    if not okLoad then return failed("MapCanvasMixin:OnLoad", loadErr) end
    for _, script in ipairs({ "OnShow", "OnHide", "OnUpdate" }) do
        if made[script] then made:SetScript(script, made[script]) end
    end
    canvas = made
    -- Hidden until it has a map and zoom levels (see settle): without them its own update fails
    -- every frame.
    scroll:Hide()
    if canvas.SetShouldZoomInOnClick then pcall(canvas.SetShouldZoomInOnClick, canvas, false) end
    if canvas.SetShouldPanOnClick then pcall(canvas.SetShouldPanOnClick, canvas, true) end

    -- The zone under the cursor is lit and named by our own hover (see hover below). Blizzard's
    -- highlight and label providers were tried first: they did light zones, but off from the
    -- cursor, and their pin sat over the map and took every click.

    -- Left-click goes into the zone under the cursor, as the world map does; a drag pans and
    -- does not count. Right-click steps out.
    local downX, downY
    scroll:HookScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then downX, downY = GetCursorPosition() end
    end)
    scroll:HookScript("OnMouseUp", function(_, button)
        if button == "RightButton" then return stepOut() end
        if button ~= "LeftButton" or not downX then return end
        local x, y = GetCursorPosition()
        local moved = math.abs(x - downX) + math.abs(y - downY)
        downX, downY = nil, nil
        if moved > 6 then return end
        -- Where on the map the cursor is, measured against the drawn surface itself. Blizzard's
        -- own answer was far off in this frame (0.21 against 0.47 on one click), ours matched.
        local current = canvas:GetMapID()
        local cx, cy = Analytics.cursorOnMap()
        local info = cx and current and C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(current, cx, cy)
        if info and info.mapID and info.mapID ~= current then clearHover(); Analytics.showMap(info.mapID) end
    end)

    local okCanvas, child = pcall(canvas.GetCanvas, canvas)
    if not okCanvas or not child then return failed("GetCanvas", child or "the map has no drawing surface") end
    fogLayer = CreateFrame("Frame", nil, child)
    fogLayer:SetAllPoints(child)
    fogLayer:SetFrameLevel((child:GetFrameLevel() or 0) + 10)
    overlay = CreateFrame("Frame", nil, child)
    overlay:SetAllPoints(child)
    overlay:SetFrameLevel((child:GetFrameLevel() or 0) + 30)
    dot = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
    dot:SetTexture("Interface\\Minimap\\MinimapArrow")
    dot:SetSize(24, 24)
    dot:Hide()
end

-- The session picker -----------------------------------------------------------------------------

local function choose(source, item)
    -- An item that cannot be shown as it is (an archived, locked session) handles the pick
    -- itself: it asks to unlock, and chooses again once it can be shown.
    if item.onChoose then return item.onChoose() end
    local ok, episode = pcall(item.episode)
    if not ok then
        GBA.Print("|cffff4040could not read that session:|r " .. tostring(episode))
        return
    end
    -- context: whose session it is (name, realm, class, race), when the source knows.
    chosen = { source = source.key, id = item.id, label = item.label, episode = episode, context = item.context }
    frame.pick:SetText(source.label .. ": " .. item.label)
    for _, layer in ipairs(layers) do
        if layer.onSession then
            local okLayer, err = pcall(layer.onSession, chosen)
            if not okLayer and GBA.recordError then pcall(GBA.recordError, "analytics " .. layer.key .. ": " .. tostring(err), "") end
        end
    end
end

-- A small list under the button: every source's sessions, newest first, a header per source.
-- A list under the button: every source's sessions, a header per source. It shows PICK_ROWS at a
-- time and the mouse wheel scrolls: a guild's bot test holds hundreds, and a list cut at the top
-- few hid every busy one.
local function drawPicker()
    local lines, offset = picker.lines, picker.offset
    for i = 1, PICK_ROWS do
        local b = picker.rows[i]
        if not b then
            b = CreateFrame("Button", nil, picker)
            b:SetHeight(14)
            b:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 14)
            b:SetPoint("RIGHT", -6, 0)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetAllPoints()
            b.text:SetJustifyH("LEFT")
            b.text:SetWordWrap(false)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            picker.rows[i] = b
        end
        local line = lines[offset + i]
        if not line then
            b:Hide()
        elseif line.header then
            b.text:SetText("|cffffd100" .. line.header .. "|r")
            b:SetScript("OnClick", nil)
            b:EnableMouse(false)
            b:Show()
        else
            b.text:SetText("   " .. line.item.label)
            b:EnableMouse(true)
            b:SetScript("OnClick", function() picker:Hide(); choose(line.source, line.item) end)
            b:Show()
        end
    end
    local shown = math.min(#lines, PICK_ROWS)
    picker:SetHeight(8 + shown * 14 + (#lines > PICK_ROWS and 14 or 0))
    if #lines > PICK_ROWS then
        picker.more:SetText(string.format("|cff999999%d-%d of %d  (mouse wheel to scroll)|r",
            offset + 1, offset + shown, #lines))
        picker.more:Show()
    else
        picker.more:Hide()
    end
end

local function openPicker()
    if not picker then
        picker = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        picker:SetPoint("TOPRIGHT", frame.pick, "BOTTOMRIGHT", 0, -2)
        picker:SetWidth(280)
        picker:SetFrameStrata("DIALOG")
        if picker.SetBackdrop then
            picker:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            picker:SetBackdropColor(0, 0, 0, 0.95)
        end
        picker.rows = {}
        picker.more = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        picker.more:SetPoint("BOTTOMLEFT", 8, 4)
        picker:EnableMouseWheel(true)
        picker:SetScript("OnMouseWheel", function(_, delta)
            local most = math.max(0, #picker.lines - PICK_ROWS)
            picker.offset = math.max(0, math.min(most, picker.offset - delta * 5))
            drawPicker()
        end)
        picker:Hide()
    end
    if picker:IsShown() then picker:Hide(); return end

    local lines = {}
    table.sort(sources, function(a, b) return (a.order or 99) < (b.order or 99) end)
    for _, source in ipairs(sources) do
        local ok, list = pcall(source.list)
        if ok and type(list) == "table" and #list > 0 then
            lines[#lines + 1] = { header = source.label .. "  |cff999999" .. #list .. "|r" }
            for i = 1, #list do lines[#lines + 1] = { source = source, item = list[i] } end
        end
    end
    if #lines == 0 then lines[1] = { header = "No sessions recorded yet" } end
    picker.lines, picker.offset = lines, 0
    drawPicker()
    picker:Show()
end

-- Side tabs and the drawer ------------------------------------------------------------------------
--
-- A panel never covers the map (docs/fix-plan.md, DEC-17): each layer with one gets a tab on the
-- frame's right edge, the spellbook's own tab where the client has the template, and opens its
-- panel in a drawer beside the frame. One drawer at a time; its tab again closes it. The drawer
-- opens on the right, or on the left when the screen has no room on the right (the frame opens
-- near the right edge).

local TAB_SIZE, TAB_STEP, TAB_GAP = 32, 44, 34
local DRAWER_WIDTH = 300
local openTab = nil     -- the layer whose drawer is open

local function hook(layer, on)
    local fn = on and layer.onShow or layer.onHide
    if not fn then return end
    local ok, err = pcall(fn, frame)
    if not ok and GBA.recordError then pcall(GBA.recordError, "analytics " .. layer.key .. ": " .. tostring(err), "") end
end

local function placeDrawer(width)
    local drawer = frame.drawer
    drawer:ClearAllPoints()
    drawer:SetWidth(width)
    local right, screen = frame:GetRight(), UIParent:GetRight()
    if right and screen and right + TAB_GAP + width > screen then
        drawer:SetPoint("TOPRIGHT", frame, "TOPLEFT", -2, 0)
        drawer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", -2, 0)
    else
        drawer:SetPoint("TOPLEFT", frame, "TOPRIGHT", TAB_GAP, 0)
        drawer:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", TAB_GAP, 0)
    end
end

local function closeDrawer()
    local layer = openTab
    if not layer then return end
    openTab = nil
    if layer.panel then layer.panel:Hide() end
    if layer.tab then layer.tab:SetChecked(false) end
    frame.drawer:Hide()
    hook(layer, false)
end

local function openDrawer(layer)
    if openTab == layer then return closeDrawer() end
    closeDrawer()
    -- Built the first time it is opened. Contained: a panel that cannot be built must not take
    -- the frame and the others with it.
    if not layer.panel and layer.build and not layer.broken then
        local ok, panel = pcall(layer.build, frame, frame.drawerArea)
        if ok then layer.panel = panel
        else
            layer.broken = true
            if GBA.recordError then pcall(GBA.recordError, "analytics " .. layer.key .. ": " .. tostring(panel), "") end
        end
    end
    openTab = layer
    placeDrawer(layer.drawerWidth or DRAWER_WIDTH)
    frame.drawer.title:SetText(layer.label)
    frame.drawer:Show()
    if layer.panel then layer.panel:Show() end
    if layer.tab then layer.tab:SetChecked(true) end
    hook(layer, true)
end

local function makeTab(index, layer)
    local name = "GuildLedgerAnalyticsTab" .. index
    local ok, tab = pcall(CreateFrame, "CheckButton", name, frame, "SpellBookSkillLineTabTemplate")
    if not ok or not tab then
        tab = CreateFrame("CheckButton", name, frame)
        tab:SetSize(TAB_SIZE, TAB_SIZE)
        local back = tab:CreateTexture(nil, "BACKGROUND")
        back:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
        back:SetSize(64, 64)
        back:SetPoint("TOPLEFT", -3, 11)
        tab:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
        tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    end
    tab:ClearAllPoints()
    tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, -36 - (index - 1) * TAB_STEP)
    tab:SetNormalTexture(layer.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    tab.tooltip = layer.label
    tab:SetScript("OnClick", function() openDrawer(layer) end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(layer.label, 1, 1, 1)
        if layer.hint then GameTooltip:AddLine(layer.hint, 0.8, 0.8, 0.8, true) end
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
    tab:SetChecked(false)
    tab:Show()
    layer.tab = tab
end

local function buildTabs()
    local drawer = CreateFrame("Frame", "GuildLedgerAnalyticsDrawer", frame, "BackdropTemplate")
    if drawer.SetBackdrop then
        drawer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        drawer:SetBackdropColor(0, 0, 0, 0.85)
    end
    drawer.title = drawer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    drawer.title:SetPoint("TOPLEFT", drawer, "TOPLEFT", 10, -8)
    local close = CreateFrame("Button", nil, drawer, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", drawer, "TOPRIGHT", 2, 2)
    close:SetScript("OnClick", closeDrawer)
    frame.drawerArea = CreateFrame("Frame", nil, drawer)
    frame.drawerArea:SetPoint("TOPLEFT", drawer, "TOPLEFT", 6, -26)
    frame.drawerArea:SetPoint("BOTTOMRIGHT", drawer, "BOTTOMRIGHT", -6, 6)
    drawer:Hide()
    frame.drawer = drawer

    local panels = {}
    for _, layer in ipairs(layers) do if layer.build then panels[#panels + 1] = layer end end
    table.sort(panels, function(a, b) return (a.order or 50) < (b.order or 50) end)
    for i, layer in ipairs(panels) do makeTab(i, layer) end
    -- Closing the frame closes its drawer, so it does not open again on a stale view.
    frame:HookScript("OnHide", closeDrawer)
end

-- Opens a layer's drawer by key, as a tab click does: for other code that wants to show one.
function Analytics.openDrawer(key)
    for _, layer in ipairs(layers) do
        if layer.key == key and layer.build then
            if openTab ~= layer then openDrawer(layer) end
            return true
        end
    end
    return false
end

local function build()
    frame = CreateFrame("Frame", "GuildLedgerAnalyticsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 40)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        frame:SetBackdropColor(0, 0, 0, 0.8)
    end
    -- Escape closes it, like any other panel.
    table.insert(UISpecialFrames, "GuildLedgerAnalyticsFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8)
    frame.title:SetPoint("RIGHT", frame, "RIGHT", -190, 0)
    frame.title:SetJustifyH("LEFT")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)

    frame.pick = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.pick:SetSize(170, 18)
    frame.pick:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -28, -5)
    frame.pick:SetText("Pick a session")
    if frame.pick:GetFontString() then frame.pick:GetFontString():SetFontObject("GameFontHighlightSmall") end
    frame.pick:SetScript("OnClick", openPicker)

    frame.note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.note:SetPoint("CENTER")
    frame.note:SetWidth(WIDTH - 60)
    frame.note:Hide()

    -- Over the map, under the title: what the map layers draw on. Panels go in the drawer.
    frame.area = CreateFrame("Frame", nil, frame)
    frame.area:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(STRIP + 26))
    frame.area:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)

    buildCanvas()
    frame.area:SetFrameLevel((frame:GetFrameLevel() or 0) + 20)
    buildTabs()

    local elapsed = 0
    local sinceHover = 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        sinceHover = sinceHover + (dt or 0)
        if elapsed >= DOT_EVERY then elapsed = 0; placeDot() end
        -- Twenty times a second, so a failure must not repeat: one error switches it off.
        if sinceHover >= HOVER_EVERY and not hoverBroken then
            sinceHover = 0
            local ok, err = pcall(hover)
            if not ok then
                hoverBroken = true
                pcall(clearHover)
                if GBA.recordError then pcall(GBA.recordError, "analytics hover: " .. tostring(err), "") end
            end
        end
    end)
    -- Opens straight into a session: the newest, this character's own first. A layer without a
    -- panel (Plays) is simply on, from the first opening; there is no box to tick. With nothing
    -- recorded yet, the map shows where the player is.
    local started = false
    frame:SetScript("OnShow", function()
        if not started then
            started = true
            for _, layer in ipairs(layers) do
                if not layer.build then hook(layer, true) end
            end
        end
        if not chosen and not Analytics.pickNewest() then Analytics.showMap(playerMap()) end
    end)
    frame:Hide()
end

-- Opens the frame (building it the first time) and returns it, or nil and why.
function Analytics.open()
    if not frame then
        local ok, err = pcall(build)
        if not ok then
            if GBA.recordError then pcall(GBA.recordError, "analytics frame: " .. tostring(err), "") end
            GBA.Print("|cffff4040the analytics frame could not open:|r " .. tostring(err))
            return nil, err
        end
    end
    frame:Show()
    return frame
end

function Analytics.toggle()
    if frame and frame:IsShown() then frame:Hide() else Analytics.open() end
end

-- A session with fewer rows than this is taken for a /reload: a few seconds, nothing to draw.
local MIN_ROWS = 50

-- Picks the newest session of the first source that has any (this character's own, first),
-- skipping /reload sessions with next to nothing in them: every reload is a session of its own
-- (DEC-12), so the newest is often one. With only those, the newest is taken anyway.
function Analytics.pickNewest()
    table.sort(sources, function(a, b) return (a.order or 99) < (b.order or 99) end)
    for _, source in ipairs(sources) do
        local ok, list = pcall(source.list)
        -- Only what can be shown: an archived session stays locked until the player unlocks it.
        local open = {}
        for _, item in ipairs(ok and type(list) == "table" and list or {}) do
            if not item.locked then open[#open + 1] = item end
        end
        if open[1] then
            local pick = open[1]
            for _, item in ipairs(open) do
                if (item.rows or 0) >= MIN_ROWS then pick = item; break end
            end
            choose(source, pick)
            return true
        end
    end
    return false
end

-- The map the player is on now, for a session with nothing of its own to show.
function Analytics.playerMap() return playerMap() end

-- Chooses a session by its source and id, as picking it in the list does. For a session that
-- has just become viewable (unlocked from the archive).
function Analytics.chooseSession(sourceKey, id)
    for _, source in ipairs(sources) do
        if source.key == sourceKey then
            local ok, list = pcall(source.list)
            for _, item in ipairs(ok and type(list) == "table" and list or {}) do
                if item.id == id and not item.locked then choose(source, item); return true end
            end
        end
    end
    return false
end

-- Unlocking an archived session (DEC-19). Adding an entry is safe; assigning the table is not.
StaticPopupDialogs["GUILDLEDGER_UNLOCK_SESSION"] = {
    text = "Unlock the session of %s?\n\nIt goes back into your pool, where you can view it again, and a data claim would send it again.",
    button1 = "Unlock",
    button2 = CANCEL or "Cancel",
    OnAccept = function(_, sid)
        if not (ns.Archive and ns.Archive.unlock) then return end
        GBA.Print("unlocking the session...")
        ns.Archive.unlock(sid, function(ok, why)
            if not ok then return GBA.Print("|cffff4040could not unlock it:|r " .. tostring(why)) end
            GBA.Print("|cff40ff40unlocked|r; the session is back in your pool")
            Analytics.chooseSession("mine", sid)
        end)
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- The key binding (Bindings.xml) calls this global; bindings cannot reach an addon's table.
BINDING_HEADER_GUILDLEDGER = "Guild Ledger"
BINDING_NAME_GUILDLEDGER_ANALYTICS = "Open the analytics map"
function GuildLedger_ToggleAnalytics() Analytics.toggle() end

