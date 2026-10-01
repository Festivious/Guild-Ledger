-- The fight card: one fight, blow by blow, beside the close-up of where it happened. The mock's card
-- (tools/mock/panel.html) in WoW frames:
--
--   headline and when
--   the strip     your health (green) and the target's (red) across the fight, a line at the chosen
--                 moment and both numbers where it crosses them; a click picks the nearest moment
--   the lanes     buffs and debuffs as spans, gained to lost
--   the moment    health, target, moving or standing, which way they faced
--   the tabs      Log (action points by global cooldown, the one holding the moment opened blow by
--                 blow), Did, Hit you, Gear (laid out as the character screen, the character dressed
--                 in the middle, standing still), Buffs
--
-- Spec: docs/superpowers/specs/2026-09-27-blow-by-blow-fights-design.md. Drawn by UI/PlaysLayer.lua,
-- which owns the state; this file only lays a play out.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema = GBA.Schema

local Card = {}
ns.FightCard = Card

Card.WIDTH = 210
local PAD = 4
local STRIP_H = 34
local LANE = 9
local MAX_LANES = 5
local ROW = 12
local SCROLLBAR = 20

local TABS = { { "log", "Log" }, { "mobs", "Mobs" }, { "did", "Did" }, { "hit", "Hit you" }, { "gear", "Gear" }, { "buffs", "Buffs" } }
local RESULT = { [1] = "crit", [2] = "miss", [3] = "dodged", [4] = "parried", [5] = "blocked", [6] = "resisted",
    [7] = "absorbed", [8] = "immune", [9] = "evaded" }
local BLOW = { [1] = { 1, 0.85, 0.4 }, [2] = { 1, 0.45, 0.35 }, [3] = { 0.45, 0.9, 0.45 }, [4] = { 0.45, 0.9, 0.45 } }
local COMPASS = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }
-- Slot numbers as the capture records them (1-19), and the character screen's own slot names,
-- whose empty-slot art GetInventorySlotInfo gives.
local SLOT = { [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [4] = "ShirtSlot", [5] = "ChestSlot",
    [6] = "WaistSlot", [7] = "LegsSlot", [8] = "FeetSlot", [9] = "WristSlot", [10] = "HandsSlot", [11] = "Finger0Slot",
    [12] = "Finger1Slot", [13] = "Trinket0Slot", [14] = "Trinket1Slot", [15] = "BackSlot", [16] = "MainHandSlot",
    [17] = "SecondaryHandSlot", [18] = "RangedSlot", [19] = "TabardSlot" }
local LEFT, RIGHT, WEAPONS = { 1, 2, 3, 15, 5, 4, 19, 9 }, { 10, 6, 7, 8, 11, 12, 13, 14 }, { 16, 17, 18 }
-- Race ids for the dress-up model: the member addon records the client's race token, the bot
-- bridge the server's number (the same ids).
local RACE = { Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5, Undead = 5, Tauren = 6, Gnome = 7, Troll = 8 }

local tiny
local function tinyFont()
    if not tiny then
        tiny = CreateFont("GuildLedgerFightCardTiny")
        tiny:SetFont(STANDARD_TEXT_FONT, 7, "")
        tiny:SetTextColor(1, 1, 1)
    end
    return tiny
end

local function hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end

local function compass(d)
    return COMPASS[math.floor(((d + 90) % 360) / 45 + 0.5) % 8 + 1]
end

-- Building, once -------------------------------------------------------------------------------------

local function texture(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r, g, b, a)
    return t
end

function Card.build(parent)
    local card = CreateFrame("Frame", nil, parent)
    card:SetWidth(Card.WIDTH)
    card:EnableMouse(true)
    texture(card, "BACKGROUND", 0, 0, 0, 0.85):SetAllPoints()
    local inner = Card.WIDTH - PAD * 2

    card.head = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.head:SetWidth(inner)
    card.head:SetJustifyH("LEFT")
    card.head:SetMaxLines(2)
    card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.sub:SetWidth(inner)
    card.sub:SetJustifyH("LEFT")
    card.sub:SetWordWrap(false)

    card.strip = CreateFrame("Frame", nil, card)
    card.strip:SetSize(inner, STRIP_H)
    texture(card.strip, "BACKGROUND", 0.05, 0.05, 0.05, 1):SetAllPoints()
    local edge = texture(card.strip, "BORDER", 0.2, 0.2, 0.2, 1)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    card.strip.lines, card.strip.used = {}, 0
    card.cursor = texture(card.strip, "OVERLAY", 1, 1, 1, 0.8)
    card.cursor:SetWidth(1)
    card.hpTag = card.strip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.tgTag = card.strip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.hpTag:SetTextColor(0.38, 0.94, 0.38)
    card.tgTag:SetTextColor(1, 0.44, 0.38)
    card.strip:EnableMouse(true)

    card.lanes = CreateFrame("Frame", nil, card)
    card.lanes:SetWidth(inner)
    card.lanes.bars, card.lanes.labels = {}, {}

    card.now = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.now:SetWidth(inner)
    card.now:SetJustifyH("LEFT")
    card.now:SetWordWrap(false)

    card.tabs = {}
    local previous
    for _, spec in ipairs(TABS) do
        local b = CreateFrame("Button", nil, card)
        b:SetHeight(14)
        b.bg = texture(b, "BACKGROUND", 0.08, 0.07, 0.04, 1)
        b.bg:SetAllPoints()
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER")
        b.text:SetText(spec[2])
        b:SetWidth(b.text:GetStringWidth() + 8)
        if previous then b:SetPoint("LEFT", previous, "RIGHT", 1, 0) end
        b.key = spec[1]
        card.tabs[#card.tabs + 1] = b
        previous = b
    end
    card.tabLine = texture(card, "ARTWORK", 0.35, 0.29, 0.12, 1)
    card.tabLine:SetHeight(1)

    card.body = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
    card.content = CreateFrame("Frame", nil, card.body)
    card.content:SetSize(inner - SCROLLBAR, 10)
    card.body:SetScrollChild(card.content)
    card.rows = {}

    card.doll = CreateFrame("Frame", nil, card)
    card.doll.slots = {}
    local okModel, model = pcall(CreateFrame, "DressUpModel", nil, card.doll)
    if okModel and model then
        card.doll.model = model
        model:SetPoint("TOP", card.doll, "TOP", 0, 0)
    end
    card.doll.name = card.doll:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.doll.name:SetPoint("TOP", card.doll, "TOP", 0, -1)
    card.doll.note = card.doll:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.doll.note:SetPoint("BOTTOM", card.doll, "BOTTOM", 0, 1)
    card.doll:Hide()

    card:Hide()
    return card
end

-- Rows under the tabs: one pool, each a button with a text on the left, an optional number on the
-- right, and an optional bar behind them.
local function row(card, i)
    local r = card.rows[i]
    if not r then
        r = CreateFrame("Button", nil, card.content)
        r.on = texture(r, "BACKGROUND", 0.35, 0.28, 0.08, 0.8)
        r.on:SetAllPoints()
        r.fill = r:CreateTexture(nil, "BORDER")
        r.fill:SetPoint("TOPLEFT", 0, 0)
        r.fill:SetPoint("BOTTOMLEFT", 0, 0)
        r.edge = texture(r, "ARTWORK", 0.23, 0.19, 0.13, 1)
        r.edge:SetPoint("TOPLEFT", 0, 0)
        r.edge:SetPoint("BOTTOMLEFT", 0, 0)
        r.edge:SetWidth(2)
        r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.right:SetPoint("TOPRIGHT", -2, -1)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetJustifyH("LEFT")
        r.text:SetJustifyV("TOP")
        card.rows[i] = r
    end
    return r
end

-- Laying one out ---------------------------------------------------------------------------------------

local function stripLine(card, x1, y1, x2, y2, r, g, b)
    local s = card.strip
    s.used = s.used + 1
    local l = s.lines[s.used]
    if not l then
        l = s:CreateLine(nil, "ARTWORK")
        s.lines[s.used] = l
    end
    l:SetColorTexture(r, g, b, 1)
    l:SetThickness(1.2)
    l:SetStartPoint("TOPLEFT", s, x1, -y1)
    l:SetEndPoint("TOPLEFT", s, x2, -y2)
    l:Show()
end

local function lastBefore(steps, kind, at)
    local v
    for _, s in ipairs(steps) do
        if s.t > at then break end
        if s.kind == kind then v = s.hp end
    end
    return v
end

-- Buffs and debuffs as spans: gained to lost, one lane each; one still up at the end runs to it.
local function spans(steps, T)
    local out, openAt = {}, {}
    for _, s in ipairs(steps) do
        if s.kind == "aura" then
            local key = tostring(s.who) .. ":" .. tostring(s.spell)
            if s.change == Schema.auraChange.lost then
                out[#out + 1] = { spell = s.spell, who = s.who, a = openAt[key] or 0, b = s.t }
                openAt[key] = nil
            else
                openAt[key] = s.t
            end
        end
    end
    for key, a in pairs(openAt) do
        local who, spell = key:match("^(%d+):(%d+)$")
        out[#out + 1] = { spell = tonumber(spell), who = tonumber(who), a = a, b = T, still = true }
    end
    table.sort(out, function(x, y) if x.a ~= y.a then return x.a < y.a end return (x.spell or 0) < (y.spell or 0) end)
    return out
end

local function drawStrip(card, steps, T, at)
    local s = card.strip
    for i = 1, s.used do s.lines[i]:Hide() end
    s.used = 0
    local w = s:GetWidth()
    local function xy(st) return st.t / T * w, 32 - (st.hp or 0) / 100 * 30 end
    for _, kind in ipairs({ "target", "health" }) do
        local prev
        for _, st in ipairs(steps) do
            if st.kind == kind and st.hp then
                if prev then
                    local x1, y1 = xy(prev)
                    local x2, y2 = xy(st)
                    if kind == "health" then stripLine(card, x1, y1, x2, y2, 0.25, 0.82, 0.25)
                    else stripLine(card, x1, y1, x2, y2, 1, 0.31, 0.25) end
                end
                prev = st
            end
        end
        -- Held flat to the end, so the last reading does not stop short of the fight.
        if prev and prev.t < T then
            local x1, y1 = xy(prev)
            if kind == "health" then stripLine(card, x1, y1, w, y1, 0.25, 0.82, 0.25)
            else stripLine(card, x1, y1, w, y1, 1, 0.31, 0.25) end
        end
    end

    local mx = at / T * w
    card.cursor:ClearAllPoints()
    card.cursor:SetPoint("TOPLEFT", s, "TOPLEFT", mx, 0)
    card.cursor:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", mx, 0)

    -- The numbers at the junction: where the moment's line crosses each health line. Nudged apart
    -- when they would sit on top of each other.
    local hp, tg = lastBefore(steps, "health", at), lastBefore(steps, "target", at)
    local function tag(fs, v, dy)
        if not v then fs:Hide(); return end
        fs:SetText(v)
        fs:ClearAllPoints()
        local y = math.max(1, math.min(STRIP_H - 9, 32 - v / 100 * 30 + dy))
        local x = mx + 2
        if x > w - 18 then x = mx - 2 - fs:GetStringWidth() end
        fs:SetPoint("TOPLEFT", s, "TOPLEFT", x, -y)
        fs:Show()
    end
    local close = hp and tg and math.abs(hp - tg) < 14
    tag(card.hpTag, hp, close and (hp >= tg and -9 or 1) or -5)
    tag(card.tgTag, tg, close and (tg > hp and -9 or 1) or -5)
    return hp, tg
end

local function drawLanes(card, steps, T)
    local list = spans(steps, T)
    local w = card.lanes:GetWidth()
    local shown = math.min(#list, MAX_LANES)
    for i = 1, shown do
        local sp = list[i]
        local bar = card.lanes.bars[i]
        if not bar then
            bar = card.lanes:CreateTexture(nil, "ARTWORK")
            card.lanes.bars[i] = bar
            local label = card.lanes:CreateFontString(nil, "OVERLAY")
            label:SetFontObject(tinyFont())
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
            card.lanes.labels[i] = label
        end
        local x = sp.a / T * w
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", card.lanes, "TOPLEFT", x, -((i - 1) * LANE + 1))
        bar:SetSize(math.max(2, (sp.b - sp.a) / T * w), LANE - 2)
        if sp.who == Schema.auraWho.target then bar:SetColorTexture(0.75, 0.44, 0.19, 0.7)
        else bar:SetColorTexture(0.29, 0.56, 0.82, 0.7) end
        bar:Show()
        local label = card.lanes.labels[i]
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", card.lanes, "TOPLEFT", math.min(x + 2, w - 40), -((i - 1) * LANE + 1))
        label:SetWidth(math.max(40, w - x - 2))
        local more = (i == shown and #list > shown) and string.format("  |cffaaaaaa+%d more: Buffs|r", #list - shown) or ""
        label:SetText(card.ctx.nm("spell", sp.spell) .. (sp.still and "" or " (lost)") .. more)
        label:Show()
    end
    for i = shown + 1, #card.lanes.bars do
        card.lanes.bars[i]:Hide()
        card.lanes.labels[i]:Hide()
    end
    card.lanes:SetHeight(math.max(1, shown * LANE))
    card.lanes:SetShown(shown > 0)
    return shown * LANE
end

-- The rows under the tabs. Each entry: text, right, colour of the text (in the text), fill (bar
-- share and colour), on (highlighted), indent, click, wrap.
local function drawRows(card, entries)
    local width = card.content:GetWidth()
    local y, holding = 0, nil
    for i, e in ipairs(entries) do
        local r = row(card, i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", card.content, "TOPLEFT", 0, -y)
        r:SetWidth(width)
        r.text:ClearAllPoints()
        r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 2 + (e.indent or 0), -1)
        r.right:SetText(e.right or "")
        r.text:SetWidth(width - 4 - (e.indent or 0) - (e.right and (r.right:GetStringWidth() + 4) or 0))
        r.text:SetWordWrap(e.wrap == true)
        r.text:SetText(e.text or "")
        local h = e.wrap and math.max(ROW, math.ceil(r.text:GetStringHeight()) + 2) or ROW
        r:SetHeight(h)
        r.on:SetShown(e.on == true)
        r.edge:SetShown(e.edge == true)
        if e.edge then
            if e.on then r.edge:SetColorTexture(1, 0.82, 0, 1) else r.edge:SetColorTexture(0.23, 0.19, 0.13, 1) end
        end
        if e.fill then
            r.fill:SetColorTexture(e.fill[2], e.fill[3], e.fill[4], 0.55)
            r.fill:SetWidth(math.max(1, width * e.fill[1]))
            r.fill:Show()
        else
            r.fill:Hide()
        end
        r:SetScript("OnClick", e.click)
        r:Show()
        if e.on and not holding then holding = y end
        y = y + h + (e.gap or 0)
    end
    for i = #entries + 1, #card.rows do card.rows[i]:Hide() end
    card.content:SetHeight(math.max(1, y))
    return holding, y
end

local function bars(entries, list, colour, total)
    local sum, top = 0, 1
    for _, e in ipairs(list) do sum, top = sum + e[2], math.max(top, e[2]) end
    total = (total and total > 0) and total or (sum > 0 and sum or 1)
    if #list == 0 then entries[#entries + 1] = { text = "|cff888888nothing|r" } end
    for _, e in ipairs(list) do
        entries[#entries + 1] = { text = e[1], right = string.format("%d (%d%%)", e[2], math.floor(e[2] / total * 100 + 0.5)),
            fill = { e[2] / top, colour[1], colour[2], colour[3] }, gap = 1 }
    end
end

local function sorted(map)
    local out = {}
    for k, v in pairs(map or {}) do out[#out + 1] = { k, v } end
    table.sort(out, function(a, b) return a[2] > b[2] end)
    return out
end

local function resultsLine(results)
    local parts = {}
    for k, n in pairs(results or {}) do parts[#parts + 1] = n .. " " .. (k == 0 and "hit" or (RESULT[k] or tostring(k))) end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function logEntries(card, play, step)
    local ctx, steps, out = card.ctx, play.steps or {}, {}
    for _, a in ipairs(play.actions or {}) do
        local holding = step >= a.first and step <= a.last
        local bits = {}
        if a.dealt > 0 then bits[#bits + 1] = "dealt " .. a.dealt .. (a.crits > 0 and (" (" .. a.crits .. " crit)") or "") end
        if a.missed > 0 then bits[#bits + 1] = a.missed .. " missed" end
        if a.takenCount > 0 then
            bits[#bits + 1] = string.format("took %d hit%s for %d%s", a.takenCount, a.takenCount > 1 and "s" or "", a.taken,
                a.avoided > 0 and (" (" .. a.avoided .. " avoided)") or "")
        end
        if a.healed > 0 then bits[#bits + 1] = "healed " .. a.healed end
        for _, g in ipairs(a.gained) do bits[#bits + 1] = "+" .. ctx.nm("spell", g) end
        for _, g in ipairs(a.lost) do bits[#bits + 1] = "-" .. ctx.nm("spell", g) end
        if a.kills > 0 then bits[#bits + 1] = "killed it" end
        if a.moving then bits[#bits + 1] = "|cff9fd0ffmoving|r" end
        local first = a.first
        local pick = function() ctx.setStep(first) end
        out[#out + 1] = { text = string.format("|cff777777%3ds|r  |cff9fd0ff%s|r", a.t,
            a.spell and ctx.nm("spell", a.spell) or "The pull"), on = holding, edge = true, click = pick }
        out[#out + 1] = { text = "|cffaaaaaa" .. (#bits > 0 and table.concat(bits, " - ") or " ") .. "|r", indent = 22,
            wrap = true, edge = true, on = holding, click = pick }
        if holding then
            for i = a.first, a.last do
                local s = steps[i]
                if s and s.kind ~= "health" and s.kind ~= "target" then
                    local c = s.kind == "blow" and BLOW[s.dir] or ctx.colour(s.kind)
                    local text = i > step and ("|cff7a7a7a" .. ctx.stepText(s) .. "|r") or (hex(c) .. ctx.stepText(s) .. "|r")
                    local at = i
                    out[#out + 1] = { text = string.format("|cff777777%3ds|r  %s", s.t, text), indent = 18,
                        on = i == step, click = function() ctx.setStep(at) end }
                end
            end
        end
        out[#out].gap = 2
    end
    if #out == 0 then out[1] = { text = "|cff888888no casts or blows recorded in this fight|r" } end
    return out
end

-- Mobs (schema 25): one card per mob of the fight (Plays.foes), each on its own timeline: who
-- started it, when it joined, what passed between it and the character, and when it died. A mob
-- that came at the character a while after the pull is an add, in orange.
local function mobEntries(card, play, T)
    local ctx, foes, out = card.ctx, play.foes or {}, {}
    local adds, old = 0, false
    for _, f in ipairs(foes) do
        if f.add then adds = adds + 1 end
        if not f.mob then old = true end
    end
    out[1] = { text = string.format("|cff888888%d mob%s%s%s|r", #foes, #foes == 1 and "" or "s",
        adds > 0 and string.format(", %d joined after the pull", adds) or "",
        old and " - an older session: mobs of one kind read as one" or ""), wrap = true, gap = 2 }
    for _, f in ipairs(foes) do
        local a = f.first or f.seen or 0
        local z = f.died or f.last or a
        local name = (f.mob and ("#" .. f.mob .. " ") or "") .. (f.npc and ctx.nm("npc", f.npc) or "unknown")
        local how = f.by == "us" and "you pulled it"
            or f.by == "them" and (f.add and string.format("came at you %d s after the pull", f.joined or 0) or "came at you")
            or "only targeted"
        local c = f.add and "|cffff9a40" or "|cffffb0a0"
        out[#out + 1] = { text = string.format("|cff777777%3ds|r  %s%s|r", a, c, name), edge = true }
        out[#out + 1] = { text = "|cffaaaaaa" .. how .. (f.died and string.format(" - died at %d s", f.died) or " - lived") .. "|r",
            indent = 22, wrap = true, edge = true }
        -- Its lane: how much of the fight it was in, from first touch to death.
        local share = math.max(0.02, (z - a) / T)
        out[#out + 1] = { text = string.format("|cffdddddd%ds - %ds|r", a, z), indent = 22, edge = true,
            fill = { share, f.add and 1 or 0.75, f.add and 0.6 or 0.31, f.add and 0.25 or 0.25 } }
        local bits = {}
        if f.dealt > 0 or f.hits > 0 then
            bits[#bits + 1] = "you dealt " .. f.dealt .. (f.crits > 0 and (" (" .. f.crits .. " crit)") or "")
                .. (f.missed > 0 and (", " .. f.missed .. " missed") or "")
        end
        if f.taken > 0 or f.hitsTaken > 0 then
            bits[#bits + 1] = string.format("it dealt %d in %d swing%s%s", f.taken, f.hitsTaken, f.hitsTaken == 1 and "" or "s",
                f.avoided > 0 and (" (" .. f.avoided .. " avoided)") or "")
        end
        if f.low then bits[#bits + 1] = "down to " .. f.low .. "%" end
        if #bits > 0 then
            out[#out + 1] = { text = "|cffaaaaaa" .. table.concat(bits, " - ") .. "|r", indent = 22, wrap = true, edge = true }
        end
        local auras = {}
        for _, x in ipairs(f.auras or {}) do
            auras[#auras + 1] = ctx.nm("spell", x.spell) .. (x.on == Schema.auraWho.self and " on you" or "")
        end
        if #auras > 0 then
            out[#out + 1] = { text = "|cff9fd0ff" .. table.concat(auras, ", ") .. "|r", indent = 22, wrap = true, edge = true }
        end
        out[#out].gap = 3
    end
    if #foes == 0 then out[#out + 1] = { text = "|cff888888no mobs in this fight|r" } end
    return out
end

-- Gear: laid out as the character screen, the character in the middle wearing exactly this.
local function drawDoll(card, play, height)
    local doll, ctx = card.doll, card.ctx
    local w = card.body:GetWidth() + SCROLLBAR
    doll:SetSize(w, height)
    local size = math.max(12, math.min(20, math.floor((height - 14) / 8)))
    local gear = play.gear or {}

    local function slotButton(slot)
        local b = doll.slots[slot]
        if not b then
            b = CreateFrame("Button", nil, doll)
            b.quality = texture(b, "BACKGROUND", 0.3, 0.3, 0.3, 1)
            b.quality:SetAllPoints()
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetPoint("TOPLEFT", 1, -1)
            b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.item then
                    if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.item)
                    else GameTooltip:SetHyperlink("item:" .. self.item) end
                else
                    GameTooltip:AddLine(_G[(SLOT[self.slot] or ""):upper()] or SLOT[self.slot] or "", 0.6, 0.6, 0.6)
                end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            doll.slots[slot] = b
        end
        b.slot, b.item = slot, gear[slot] and gear[slot] > 0 and gear[slot] or nil
        b:SetSize(size, size)
        if b.item then
            local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(b.item)) or GetItemIcon(b.item)
            b.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            b.icon:SetDesaturated(false)
            local quality = select(3, GetItemInfo(b.item))
            local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
            if qc then b.quality:SetColorTexture(qc.r, qc.g, qc.b, 1) else b.quality:SetColorTexture(0.3, 0.3, 0.3, 1) end
        else
            local _, empty = GetInventorySlotInfo(SLOT[slot])
            b.icon:SetTexture(empty)
            b.icon:SetDesaturated(true)
            b.quality:SetColorTexture(0.15, 0.15, 0.15, 1)
        end
        b:Show()
        return b
    end

    for i, slot in ipairs(LEFT) do
        slotButton(slot):SetPoint("TOPLEFT", doll, "TOPLEFT", 2, -(i - 1) * (size + 2))
    end
    for i, slot in ipairs(RIGHT) do
        slotButton(slot):SetPoint("TOPRIGHT", doll, "TOPRIGHT", -2, -(i - 1) * (size + 2))
    end
    local row = #WEAPONS * size + (#WEAPONS - 1) * 2
    for i, slot in ipairs(WEAPONS) do
        slotButton(slot):SetPoint("BOTTOMLEFT", doll, "BOTTOM", -row / 2 + (i - 1) * (size + 2), 12)
    end

    local who = ctx.context or {}
    doll.name:SetText(who.name or "")
    local worn = 0
    for _ in pairs(gear) do worn = worn + 1 end
    doll.note:SetText(worn == 0 and "no gear recorded for this fight" or "as worn at the pull")

    local model = doll.model
    if not model then return end
    model:ClearAllPoints()
    model:SetPoint("TOPLEFT", doll, "TOPLEFT", size + 6, -10)
    model:SetPoint("BOTTOMRIGHT", doll, "BOTTOMRIGHT", -(size + 6), size + 14)
    -- Dressed once per play and gear: a model re-dressed on every step would flicker.
    local key = tostring(play.n) .. ":" .. tostring(who.name)
    for slot, item in pairs(gear) do key = key .. ":" .. slot .. "=" .. item end
    if doll.dressed == key then return end
    doll.dressed = key
    local function dress()
        pcall(model.SetUnit, model, "player")
        local mine = who.name == nil or (who.name == UnitName("player") and (who.realm == nil or who.realm == GetRealmName()))
        if not mine then
            local race = type(who.race) == "number" and who.race or RACE[who.race or ""]
            if race and model.SetCustomRace then pcall(model.SetCustomRace, model, race, 0) end
        end
        pcall(model.Undress, model)
        for _, item in pairs(gear) do
            if item > 0 then pcall(model.TryOn, model, "item:" .. item) end
        end
        -- Standing, still: the idle stand, frozen.
        if model.FreezeAnimation then pcall(model.FreezeAnimation, model, 0, 0, 0)
        elseif model.SetAnimation then pcall(model.SetAnimation, model, 0) end
        pcall(model.SetRotation, model, 0.35)
    end
    dress()
    -- Items the client has not seen yet dress as nothing the first time: asked for, then again.
    C_Timer.After(0.6, function() if doll.dressed == key and doll:IsShown() then dress() end end)
end

-- ctx: { nm, stepText, headline, clock, colour(kind) -> rgb, setStep(i), tab, setTab(key), context,
--        height: the card's height, given because a card just shown may not have been sized yet }
function Card.draw(card, play, step, ctx)
    card.ctx = ctx
    local steps = play.steps or {}
    local T = math.max(1, play.seconds or 1)
    local cur = steps[step]
    local at = cur and cur.t or 0

    local y = PAD
    card.head:ClearAllPoints()
    card.head:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    card.head:SetText(ctx.headline(play))
    y = y + math.ceil(card.head:GetStringHeight()) + 1
    card.sub:ClearAllPoints()
    card.sub:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    card.sub:SetText(ctx.clock(play.t0) .. ((play.subzone or "") ~= "" and (" - " .. play.subzone) or ""))
    y = y + 12

    card.strip:ClearAllPoints()
    card.strip:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    local hp, tg = drawStrip(card, steps, T, at)
    card.strip:SetScript("OnMouseDown", function(self)
        local x = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
        local t = x / self:GetWidth() * T
        local best, gap = 1, math.huge
        for i, s in ipairs(steps) do
            if s.kind ~= "health" and s.kind ~= "target" then
                local g = math.abs(s.t - t)
                if g < gap or (g == gap and s.kind == "blow") then best, gap = i, g end
            end
        end
        ctx.setStep(best)
    end)
    y = y + STRIP_H + 2

    card.lanes:ClearAllPoints()
    card.lanes:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    local lanes = drawLanes(card, steps, T)
    y = y + lanes + (lanes > 0 and 2 or 0)

    local now = string.format("at %d s: you %s%%", at, hp and tostring(hp) or "?")
    if tg then now = now .. ", target " .. tg .. "%" end
    if cur and cur.facing then now = now .. ", " .. (cur.moving and "moving" or "standing") .. ", facing " .. compass(cur.facing) end
    card.now:ClearAllPoints()
    card.now:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    card.now:SetText(now)
    y = y + 13

    for i, b in ipairs(card.tabs) do
        b:ClearAllPoints()
        if i == 1 then b:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
        else b:SetPoint("LEFT", card.tabs[i - 1], "RIGHT", 1, 0) end
        local on = b.key == ctx.tab
        b.bg:SetColorTexture(on and 0.16 or 0.08, on and 0.13 or 0.07, on and 0.06 or 0.04, 1)
        b.text:SetTextColor(on and 1 or 0.67, on and 0.82 or 0.67, on and 0 or 0.67)
        local key = b.key
        b:SetScript("OnClick", function() ctx.setTab(key) end)
    end
    y = y + 14
    card.tabLine:ClearAllPoints()
    card.tabLine:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    card.tabLine:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
    y = y + 3

    -- Only what is under the tabs scrolls; the headline, strip and moment stay put.
    local height = math.max(20, (ctx.height or card:GetHeight() or 200) - y - PAD)
    card.body:ClearAllPoints()
    card.body:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    card.body:SetSize(Card.WIDTH - PAD * 2 - SCROLLBAR, height)
    card.content:SetWidth(Card.WIDTH - PAD * 2 - SCROLLBAR)
    card.doll:ClearAllPoints()
    card.doll:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)

    if ctx.tab == "gear" then
        card.body:Hide()
        card.doll:Show()
        drawDoll(card, play, height)
        return
    end
    card.doll:Hide()
    card.body:Show()

    local b = play.blows or {}
    local entries
    if ctx.tab == "did" then
        local dealt = b.dealt or {}
        entries = { { text = string.format("|cff888888%d damage, %s|r", dealt.total or 0, resultsLine(dealt.results)), wrap = true } }
        local list = {}
        for _, e in ipairs(sorted(dealt.bySpell)) do list[#list + 1] = { e[1] == 0 and "Melee" or ctx.nm("spell", e[1]), e[2] } end
        bars(entries, list, { 1, 0.85, 0.4 })
        if b.healDealt and (b.healDealt.total or 0) > 0 then
            entries[#entries + 1] = { text = "|cff888888healing|r" }
            list = {}
            for _, e in ipairs(sorted(b.healDealt.bySpell)) do list[#list + 1] = { ctx.nm("spell", e[1]), e[2] } end
            bars(entries, list, { 0.45, 0.9, 0.45 })
        end
    elseif ctx.tab == "hit" then
        local taken = b.taken or {}
        entries = { { text = string.format("|cff888888%d damage taken, %s|r", taken.total or 0, resultsLine(taken.results)), wrap = true } }
        local list = {}
        for _, e in ipairs(sorted(taken.byNpc)) do list[#list + 1] = { e[1] == 0 and "Unknown" or ctx.nm("npc", e[1]), e[2] } end
        bars(entries, list, { 1, 0.45, 0.35 })
        if b.healTaken and (b.healTaken.total or 0) > 0 then
            entries[#entries + 1] = { text = "|cff888888healed|r" }
            list = {}
            for _, e in ipairs(sorted(b.healTaken.bySpell)) do list[#list + 1] = { e[1] == 0 and "Unknown" or ctx.nm("spell", e[1]), e[2] } end
            bars(entries, list, { 0.45, 0.9, 0.45 })
        end
    elseif ctx.tab == "mobs" then
        entries = mobEntries(card, play, T)
    elseif ctx.tab == "buffs" then
        entries = {}
        for i, s in ipairs(steps) do
            if s.kind == "aura" then
                local at_ = i
                local c = s.change == Schema.auraChange.lost and "|cff999999" or "|cff9fd0ff"
                entries[#entries + 1] = { text = string.format("|cff777777%3ds|r  %s%s|r", s.t, c, ctx.stepText(s)),
                    on = i == step, click = function() ctx.setStep(at_) end }
            end
        end
        if #entries == 0 then entries[1] = { text = "|cff888888no buffs or debuffs changed|r" } end
    else
        entries = logEntries(card, play, step)
    end

    local holding, total = drawRows(card, entries)
    -- The list scrolled to the moment, not the whole card.
    local range = math.max(0, total - height)
    card.body:SetVerticalScroll(holding and math.max(0, math.min(range, holding - height / 3)) or 0)
end
