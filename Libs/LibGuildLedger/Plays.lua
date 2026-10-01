-- CAT, the character analysis translation layer: a session's rows become plays. Pure, no WoW API.
--
-- Rows are the retained episode rows (code, values, chain) that Replay also reads. A play is one
-- thing the character did at one place:
--
--   fight   every row carrying one fight number (the capture stamps them), plus what follows at
--           the corpse within a few seconds: the kill, the loot, the skin, the experience
--   death   the death, the ghost's walk back, until health comes back
--   rest    sitting down to eat or drink, until the character moves off; crafts made there
--   gather  one herb or ore node
--   town    quest hand-ins and pickups close together, and the experience they paid
--
-- Walking is not a play: it is the route between two plays. Skill-ups and level-ups are badges on
-- the play they happened in. Every play is placed on the map, inside a fence if it is in one of
-- the Questie camps (Fields.lua), and under the minimap subzone the character was in (the session's own subzone
-- rows, schema 23; older sessions have none and their plays simply have no subzone).
--
-- Nothing here names anything. Plays carry ids; whoever draws them resolves names.
-- Spec: docs/superpowers/specs/2026-09-26-cat-plays-design.md.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Schema, Coords
if ns then
    Schema, Coords = ns.Schema, ns.Coords
else
    Schema, Coords = require("Schema"), require("Coords")
end

local F = Schema.factType

local Plays = {}

Plays.AFTER_FIGHT = 10       -- seconds after a fight in which the corpse's rows still belong to it
Plays.ADD_GAP = 3            -- a new pull this soon after the last is the same fight (an add)
Plays.TOWN_GAP = 60          -- quest rows this close together are one town visit
Plays.REST_LIMIT = 150       -- a rest nobody got up from is cut here
Plays.MOVED = 0.006          -- moving this far from where they sat ends a rest
-- Casts that do not start the global cooldown, so do not open an action point: auto-shot, the wand,
-- and the potions. The data does not say which casts start it; until the capture records that,
-- every other cast is taken to.
Plays.OFF_GCD = { [75] = true, [5019] = true, [6603] = true, [439] = true, [440] = true, [441] = true,
    [2023] = true, [2024] = true }
Plays.FOOD = { [433] = "eat", [434] = "eat", [435] = "eat", [1127] = "eat", [1129] = "eat",
               [430] = "drink", [431] = "drink", [432] = "drink", [1133] = "drink", [1135] = "drink" }

local function inside(hull, x, y)
    local n, hit = #hull / 2, false
    local j = n
    for i = 1, n do
        local xi, yi, xj, yj = hull[2 * i - 1], hull[2 * i], hull[2 * j - 1], hull[2 * j]
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then hit = not hit end
        j = i
    end
    return hit
end

-- The field a spot is in, if any.
function Plays.fieldAt(fields, mapID, x, y)
    local zone = fields and fields[mapID]
    for _, field in ipairs(zone and zone.fields or {}) do
        if inside(field.hull, x, y) then return field.id end
    end
    return nil
end

local function ordered(rows)
    local out = {}
    for i, row in ipairs(rows) do out[i] = row end
    table.sort(out, function(a, b)
        local at, bt = a.chain.t or 0, b.chain.t or 0
        if at ~= bt then return at < bt end
        return (a.chain.seq or 0) < (b.chain.seq or 0)
    end)
    return out
end

-- rows: the session's rows ({ code, values, chain }, as an episode holds them). fields: the
-- Fields data (map id -> { fields = {...} }), or nil where there is none.
function Plays.build(rows, fields)
    rows = ordered(rows)

    -- The walked line, the health line and the minimap's names, for placing and describing
    -- everything else.
    -- Poses (every half second in a fight, schema 24) join the walked line, with their facing,
    -- so a fight's route and "where was I at this moment" come from them. Gear rows are kept as
    -- a running record: a fight carries the whole set worn when it ended.
    local track, health, subzones, gearLog = {}, {}, {}, {}
    for _, row in ipairs(rows) do
        local v = row.values
        if row.code == F.subzone then
            subzones[#subzones + 1] = { t = row.chain.t, map = v.mapID, name = v.name or "" }
        elseif (row.code == F.position or row.code == F.pose) and v.coord then
            local x, y = Coords.unpack(v.coord)
            track[#track + 1] = { t = row.chain.t, map = v.mapID, x = x, y = y, facing = v.facing,
                moving = v.moving == 1 or nil, pose = row.code == F.pose or nil }
        elseif row.code == F.gear then
            gearLog[#gearLog + 1] = { t = row.chain.t, slot = v.slot, item = v.itemID }
        elseif row.code == F.vitals then
            health[#health + 1] = { t = row.chain.t, hp = v.healthPct, power = v.powerPct, combat = v.inCombat == 1 }
        end
    end
    -- Every equipped slot as it stood at time t.
    local function gearAt(t)
        local worn = {}
        for _, g in ipairs(gearLog) do
            if (g.t or 0) > t then break end
            worn[g.slot] = (g.item and g.item > 0) and g.item or nil
        end
        return worn
    end

    -- The last sample at or before t. Binary search: it is asked once per step, and a long
    -- session has thousands of both, which a scan would turn into millions of comparisons in a
    -- client that stops scripts that run too long.
    local function whereAt(t)
        local lo, hi, best = 1, #track, nil
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if (track[mid].t or 0) <= (t or 0) then best = track[mid]; lo = mid + 1 else hi = mid - 1 end
        end
        return best or track[1]
    end
    local function trackBetween(t0, t1)
        local out = {}
        for _, p in ipairs(track) do
            if p.t >= t0 and p.t <= t1 then out[#out + 1] = p end
        end
        return out
    end

    local plays, claimed = {}, {}
    local function newPlay(kind, t0)
        local play = { kind = kind, t0 = t0, t1 = t0, rows = {}, badges = {} }
        plays[#plays + 1] = play
        return play
    end
    local function take(play, i)
        claimed[i] = true
        local row = rows[i]
        play.rows[#play.rows + 1] = row
        if row.chain.t and row.chain.t > play.t1 then play.t1 = row.chain.t end
        if row.chain.t and row.chain.t < play.t0 then play.t0 = row.chain.t end
    end

    -- Fights: everything under one fight number, adds folded in. Kills and what they dropped are
    -- not taken by number: until 2026-09-30 a kill was stamped with the fight running when it was
    -- written, minutes after it died, and one such row stretched a fight over everything played
    -- in between. They join the fight they happened in by time, below.
    local BY_TIME = { [F.position] = true, [F.vitals] = true, [F.subzone] = true, [F.pose] = true, [F.gear] = true,
        [F.kill] = true, [F.loot_drop] = true, [F.npc_spawn] = true }
    local byFight, fightOrder = {}, {}
    for i, row in ipairs(rows) do
        local id = row.chain.encounterID
        if id and not BY_TIME[row.code] then
            if not byFight[id] then byFight[id] = {}; fightOrder[#fightOrder + 1] = id end
            table.insert(byFight[id], i)
        end
    end
    local last
    for _, id in ipairs(fightOrder) do
        local first = rows[byFight[id][1]].chain.t
        local play = (last and first - last.t1 <= Plays.ADD_GAP) and last or newPlay("fight", first)
        play.fights = (play.fights or 0) + 1
        for _, i in ipairs(byFight[id]) do take(play, i) end
        last = play
    end
    -- What follows at the corpse.
    for _, play in ipairs(plays) do
        local ended = play.t1
        for i, row in ipairs(rows) do
            local t = row.chain.t or 0
            -- From the pull on, not only after the end: in game the kill is logged a moment before
            -- combat ends (the mob dies, then the character drops out of combat).
            if not claimed[i] and t >= play.t0 and t <= ended + Plays.AFTER_FIGHT then
                local v = row.values
                if (row.code == F.kill and v.participated == Schema.participation.participated)
                    or row.code == F.loot_drop
                    or (row.code == F.gathered and v.kind == 3)
                    or (row.code == F.xp_gain and v.source == Schema.xpSource.kill) then
                    take(play, i)
                end
            end
        end
    end

    -- Deaths: until health comes back.
    for i, row in ipairs(rows) do
        if row.code == F.player_death then
            local t0 = row.chain.t
            local play = newPlay("death", t0)
            play.killer = row.values.killerNpcID
            claimed[i] = true
            play.rows[1] = row
            play.t1 = t0
            for _, h in ipairs(health) do
                if h.t > t0 and (h.hp or 0) > 0 then play.t1 = h.t; break end
            end
            for _, fight in ipairs(plays) do
                if fight.kind == "fight" and fight.t0 <= t0 and fight.t1 >= t0 then fight.died = true end
            end
        end
    end

    -- Rests: eating or drinking, until they move off.
    local resting
    for i, row in ipairs(rows) do
        if not claimed[i] and row.code == F.spell_cast and Plays.FOOD[row.values.spellID] then
            local t = row.chain.t
            if resting and t <= resting.t1 then
                take(resting, i)
            else
                resting = newPlay("rest", t)
                take(resting, i)
                local start = whereAt(t)
                resting.t1 = math.min(t + Plays.REST_LIMIT, (track[#track] or {}).t or t)
                for _, p in ipairs(track) do
                    if p.t > t and start and math.sqrt((p.x - start.x) ^ 2 + (p.y - start.y) ^ 2) > Plays.MOVED then
                        resting.t1 = p.t; break
                    end
                end
                for _, h in ipairs(health) do
                    if h.t > t and h.combat then resting.t1 = math.min(resting.t1, h.t); break end
                end
            end
        end
    end
    -- Crafts made where they sat.
    for i, row in ipairs(rows) do
        if not claimed[i] and row.code == F.crafted then
            for _, play in ipairs(plays) do
                if play.kind == "rest" and row.chain.t >= play.t0 and row.chain.t <= play.t1 + 30 then take(play, i); break end
            end
        end
    end

    -- Gathering: one node each.
    local node
    for i, row in ipairs(rows) do
        if not claimed[i] and row.code == F.gathered and row.values.kind ~= 3 then
            if row.values.lootIndex == 1 or not node or row.chain.t ~= node.t0 then
                node = newPlay("gather", row.chain.t)
                node.node = row.values.sourceID
            end
            take(node, i)
        end
    end

    -- Town: quest rows close together, and the experience they paid.
    local town
    for i, row in ipairs(rows) do
        if not claimed[i] and row.code == F.quest_event then
            if not town or row.chain.t - town.t1 > Plays.TOWN_GAP then town = newPlay("town", row.chain.t) end
            take(town, i)
        end
    end
    for i, row in ipairs(rows) do
        if not claimed[i] and row.code == F.xp_gain and row.values.source ~= Schema.xpSource.kill then
            for _, play in ipairs(plays) do
                if play.kind == "town" and math.abs(row.chain.t - play.t0) <= 5 then take(play, i); break end
            end
        end
    end

    table.sort(plays, function(a, b) return a.t0 < b.t0 end)

    -- Badges: skill-ups and level-ups land on the play they happened in, or the one just before.
    local function playAt(t)
        local best
        for _, play in ipairs(plays) do
            if play.t0 <= t then best = play end
            if play.t0 <= t and t <= play.t1 + Plays.AFTER_FIGHT then return play end
        end
        return best
    end
    local level
    for i, row in ipairs(rows) do
        local v = row.values
        if v.observerLevel then
            if level and v.observerLevel > level then
                local play = playAt(row.chain.t)
                if play then play.badges[#play.badges + 1] = { kind = "level", level = v.observerLevel, t = row.chain.t } end
            end
            level = v.observerLevel
        end
        if row.code == F.skill_up and not claimed[i] then
            local play = playAt(row.chain.t)
            if play then play.badges[#play.badges + 1] = { kind = "skill", skill = v.skillLine, to = v.toValue, t = row.chain.t } end
        end
    end

    -- Place, field, subzone, route, and a step list for each play.
    local function subzoneAt(t, mapID)
        local name = ""
        for _, s in ipairs(subzones) do
            if s.t <= t then if s.map == mapID then name = s.name end else break end
        end
        return name
    end

    local prev
    for n, play in ipairs(plays) do
        play.n = n
        -- Where: the kill, the death, the node, else where they stood.
        local spot
        for _, row in ipairs(play.rows) do
            local v = row.values
            if v.coord and (row.code == F.kill or row.code == F.player_death or row.code == F.gathered) then
                local x, y = Coords.unpack(v.coord)
                spot = { map = v.mapID, x = x, y = y }
                break
            end
        end
        if not spot then
            local p = whereAt(play.t0)
            spot = p and { map = p.map, x = p.x, y = p.y } or { map = nil, x = 0.5, y = 0.5 }
        end
        play.map, play.x, play.y = spot.map, spot.x, spot.y
        play.fence = Plays.fieldAt(fields, play.map, play.x, play.y)
        play.subzone = subzoneAt(play.t0, play.map)
        play.path = trackBetween(play.t0, play.t1)

        -- The route here from the last play: the walked line, how far and how long.
        if prev then
            local route = trackBetween(prev.t1, play.t0)
            local length = 0
            for k = 2, #route do
                if route[k].map == route[k - 1].map then
                    length = length + math.sqrt((route[k].x - route[k - 1].x) ^ 2 + (route[k].y - route[k - 1].y) ^ 2)
                end
            end
            play.route = { path = route, seconds = play.t0 - prev.t1, length = length }
        end

        -- Health through the play, and its low point.
        play.health = {}
        for _, h in ipairs(health) do
            if h.t >= play.t0 and h.t <= play.t1 then
                play.health[#play.health + 1] = { t = h.t, hp = h.hp, power = h.power }
                if not play.low or h.hp < play.low then play.low = h.hp end
            end
        end

        -- The steps, in order, for walking through the play one at a time.
        local steps = {}
        local function step(t, kind, fields_, x, y)
            fields_.t, fields_.kind = t, kind
            if x then fields_.x, fields_.y = x, y end
            steps[#steps + 1] = fields_
        end
        local mobs, items, xp = {}, {}, 0
        -- The blows, added up: dealt and taken, healing done and received, each by spell and by
        -- enemy, for the fight card's bars.
        local blows = {}
        for _, key in ipairs({ "dealt", "taken", "healDealt", "healTaken" }) do
            blows[key] = { total = 0, count = 0, bySpell = {}, byNpc = {}, results = {} }
        end
        local dirKey = { [Schema.blowDir.dealt] = "dealt", [Schema.blowDir.taken] = "taken",
            [Schema.blowDir.healDealt] = "healDealt", [Schema.blowDir.healTaken] = "healTaken" }
        for _, row in ipairs(play.rows) do
            local v, t = row.values, row.chain.t
            local x, y
            if v.coord then x, y = Coords.unpack(v.coord) end
            if row.code == F.npc_spawn then step(t, "pull", { npc = v.npcID }, x, y); mobs[v.npcID] = mobs[v.npcID] or 0
            elseif row.code == F.spell_cast then step(t, Plays.FOOD[v.spellID] or "cast", { spell = v.spellID, npc = v.targetNpcID, mob = v.targetMob }, x, y)
            elseif row.code == F.kill then step(t, "kill", { npc = v.npcID, mob = v.mob }, x, y); mobs[v.npcID] = (mobs[v.npcID] or 0) + 1
            elseif row.code == F.loot_drop then step(t, "loot", { item = v.itemID, count = v.quantity }, x, y); items[#items + 1] = v.itemID
            elseif row.code == F.gathered then step(t, v.kind == 3 and "skin" or "gather", { item = v.itemID, count = v.quantity }, x, y); items[#items + 1] = v.itemID
            elseif row.code == F.crafted then step(t, "craft", { item = v.itemID, count = v.quantity }, x, y); items[#items + 1] = v.itemID
            elseif row.code == F.xp_gain then step(t, "xp", { amount = v.amount }); xp = xp + (v.amount or 0)
            elseif row.code == F.player_death then step(t, "death", { npc = v.killerNpcID }, x, y)
            elseif row.code == F.quest_event then
                step(t, v.action == Schema.questAction.turnedIn and "handin" or v.action == Schema.questAction.accepted and "accept" or "abandon", { quest = v.questID })
            elseif row.code == F.encounter then step(t, "fightEnd", { seconds = v.duration })
            elseif row.code == F.blow then
                step(t, "blow", { dir = v.dir, spell = v.spellID, npc = v.npcID, amount = v.amount,
                    result = v.result, absorbed = v.absorbed, mob = v.mob })
                local b = blows[dirKey[v.dir] or "dealt"]
                local amount = v.amount or 0
                b.total, b.count = b.total + amount, b.count + 1
                local spell, npc = v.spellID or 0, v.npcID or 0
                b.bySpell[spell] = (b.bySpell[spell] or 0) + amount
                b.byNpc[npc] = (b.byNpc[npc] or 0) + amount
                b.results[v.result or 0] = (b.results[v.result or 0] or 0) + 1
            elseif row.code == F.aura then
                step(t, "aura", { who = v.who, spell = v.spellID, change = v.change, npc = v.npcID, mob = v.mob })
            elseif row.code == F.target then
                step(t, "target", { npc = v.npcID, hp = v.healthPct, mob = v.mob })
            end
        end
        for _, h in ipairs(play.health) do step(h.t, "health", { hp = h.hp, power = h.power }) end
        for _, b in ipairs(play.badges) do step(b.t, b.kind, { level = b.level, skill = b.skill, to = b.to }) end
        -- By time, and within a second in the order they were recorded: a cast and the hit it
        -- made land in the same second, and an unstable sort put the hit first.
        for i, st in ipairs(steps) do st.order = i end
        table.sort(steps, function(a, b)
            if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) < (b.t or 0) end
            return a.order < b.order
        end)
        for _, st in ipairs(steps) do st.order = nil end
        -- A step with no place of its own happened where they were standing.
        for _, s in ipairs(steps) do
            local p = whereAt(s.t)
            if p then
                if not s.x then s.x, s.y = p.x, p.y end
                -- Which way they faced and whether they were moving, from the nearest pose.
                s.facing, s.moving = p.facing, p.moving
            end
            s.t = (s.t or play.t0) - play.t0
        end
        play.steps, play.mobs, play.items, play.xp = steps, mobs, items, xp
        play.blows = blows
        play.gear = gearAt(play.t1)
        play.actions = Plays.actions(steps)
        if play.kind == "fight" then play.foes = Plays.foes(steps) end
        play.seconds = play.t1 - play.t0
        play.rows = nil
        prev = play
    end

    return plays
end

-- Action points: a fight's steps grouped by the character's global cooldown. Each spell cast that
-- starts the GCD opens one, and everything until the next belongs to it: swings, hits taken,
-- potions, buffs. What comes before the first is the opening (the pull). Each point says what it
-- held, added up, and which steps it spans (first, last), so a screen can open it blow by blow.
function Plays.actions(steps)
    local out, current = {}, nil
    local function open(i, s, cast)
        current = { first = i, last = i, t = s.t, spell = cast and s.spell or nil, npc = cast and s.npc or nil,
            dealt = 0, dealtBy = {}, taken = 0, takenCount = 0, healed = 0, crits = 0, avoided = 0, missed = 0,
            gained = {}, lost = {}, moving = false, kills = 0 }
        out[#out + 1] = current
    end
    for i, s in ipairs(steps or {}) do
        local starts = s.kind == "cast" and s.spell and not Plays.OFF_GCD[s.spell]
        if starts or not current then open(i, s, starts) end
        local a = current
        a.last = i
        if s.moving then a.moving = true end
        if s.kind == "blow" then
            local amount = s.amount or 0
            local R = Schema.blowResult
            if s.dir == Schema.blowDir.dealt then
                a.dealt = a.dealt + amount
                a.dealtBy[s.spell or 0] = (a.dealtBy[s.spell or 0] or 0) + amount
                if s.result == R.crit then a.crits = a.crits + 1 end
                if s.result == R.miss or s.result == R.dodge or s.result == R.parry then a.missed = a.missed + 1 end
            elseif s.dir == Schema.blowDir.taken then
                a.taken, a.takenCount = a.taken + amount, a.takenCount + 1
                if s.result == R.miss or s.result == R.dodge or s.result == R.parry or s.result == R.block then
                    a.avoided = a.avoided + 1
                end
            else
                a.healed = a.healed + amount
            end
        elseif s.kind == "aura" then
            local list = s.change == Schema.auraChange.lost and a.lost or a.gained
            list[#list + 1] = s.spell
        elseif s.kind == "health" then
            a.hpStart = a.hpStart or s.hp
            a.hpEnd = s.hp
        elseif s.kind == "kill" then
            a.kills = a.kills + 1
        end
    end
    return out
end

-- The mobs of one fight, each on its own timeline (schema 25): when it first touched the fight and
-- who started it, the blows each way, what was put on it, its health as the target showed it, and
-- when it died. A mob that came at the character a while after the pull is an add. Rows from
-- before schema 25 carry no mob number; their mobs are told apart by kind only, so two of the
-- same kind read as one.
Plays.ADD_LATE = 2   -- seconds after the pull from which a mob that joins counts as an add
local B_DEALT, B_TAKEN = 1, 2

function Plays.foes(steps)
    local byKey, out = {}, {}
    local function foe(s)
        if not s.mob and not (s.npc and s.npc > 0) then return nil end
        local key = s.mob or -s.npc
        local f = byKey[key]
        if not f then
            f = { mob = s.mob, npc = (s.npc and s.npc > 0) and s.npc or nil, seen = s.t, dealt = 0, taken = 0,
                  hits = 0, hitsTaken = 0, crits = 0, avoided = 0, missed = 0, auras = {}, health = {} }
            byKey[key] = f
            out[#out + 1] = f
        end
        if not f.npc and s.npc and s.npc > 0 then f.npc = s.npc end
        f.last = s.t
        return f
    end
    -- First touched: a blow either way, a cast at it, an aura. Being targeted is only seen.
    local function touch(f, by)
        if not f then return nil end
        f.by = f.by or by
        f.first = f.first or f.last
        return f
    end
    local R = Schema.blowResult
    for _, s in ipairs(steps) do
        local f
        if s.kind == "blow" and (s.dir == B_DEALT or s.dir == B_TAKEN) then
            f = foe(s)
            if f then
                local amount = s.amount or 0
                if s.dir == B_DEALT then
                    touch(f, "us")
                    f.dealt, f.hits = f.dealt + amount, f.hits + 1
                    if s.result == R.crit then f.crits = f.crits + 1 end
                    if s.result == R.miss or s.result == R.dodge or s.result == R.parry then f.missed = f.missed + 1 end
                else
                    touch(f, "them")
                    f.taken, f.hitsTaken = f.taken + amount, f.hitsTaken + 1
                    if s.result == R.miss or s.result == R.dodge or s.result == R.parry or s.result == R.block then
                        f.avoided = f.avoided + 1
                    end
                end
            end
        elseif s.kind == "cast" and (s.mob or (s.npc and s.npc > 0)) then
            f = foe(s)
            touch(f, "us")
        elseif s.kind == "aura" then
            f = foe(s)
            if f then
                -- On the target: something the character put on it. On the character: its doing.
                touch(f, s.who == Schema.auraWho.target and "us" or "them")
                if s.change == Schema.auraChange.gained then f.auras[#f.auras + 1] = { t = s.t, spell = s.spell, on = s.who } end
            end
        elseif s.kind == "target" then
            f = foe(s)
            if f and s.hp then f.health[#f.health + 1] = { t = s.t, hp = s.hp } end
        elseif s.kind == "kill" then
            f = foe(s)
            if f then f.died = s.t end
        end
    end
    -- The pull: the first time the character and any mob touched. Seeing a target is not touching.
    local pull
    for _, f in ipairs(out) do
        if f.first and (not pull or f.first < pull) then pull = f.first end
    end
    table.sort(out, function(a, b) return (a.first or a.seen) < (b.first or b.seen) end)
    for _, f in ipairs(out) do
        f.joined = (pull and f.first) and (f.first - pull) or nil
        f.add = f.by == "them" and (f.joined or 0) >= Plays.ADD_LATE
        f.low = nil
        for _, h in ipairs(f.health) do if not f.low or h.hp < f.low then f.low = h.hp end end
    end
    return out
end

-- Plays gathered into places. A field is where the character stayed and fought: a fight with at
-- least FIELD_NEIGHBOURS other fights within FIELD_YARDS is a field's core, cores that near each
-- other chain into one field, and any play that near a core joins it. A kill on the way somewhere
-- has a neighbour or two and never makes a core. The plays between two fields are path legs, one
-- per stretch. The Questie camps (Fields.lua) are fences: they say which camp a field sits in
-- ("7 of 9 inside"), they never decide the grouping.
-- sizeOf(mapID) -> width, height of the map in yards; nil uses a rough zone size.
-- Returns groups in the order they were first played in.
Plays.FIELD_YARDS = 50
Plays.FIELD_NEIGHBOURS = 3
Plays.ZONE_YARDS = { 3500, 2333 }

function Plays.groups(plays, sizeOf)
    local function yards(mapID)
        local w, h
        if sizeOf then w, h = sizeOf(mapID) end
        if not w or w <= 0 or not h or h <= 0 then w, h = Plays.ZONE_YARDS[1], Plays.ZONE_YARDS[2] end
        return w, h
    end
    local function near(a, b)
        if a.map ~= b.map or not a.map then return false end
        local w, h = yards(a.map)
        return ((a.x - b.x) * w) ^ 2 + ((a.y - b.y) * h) ^ 2 <= Plays.FIELD_YARDS ^ 2
    end

    -- The cores, and the fields they chain into.
    local core, fieldOf = {}, {}
    for i, p in ipairs(plays) do
        if p.kind == "fight" then
            local n = 0
            for j, q in ipairs(plays) do
                if j ~= i and q.kind == "fight" and near(p, q) then n = n + 1 end
            end
            core[i] = n >= Plays.FIELD_NEIGHBOURS
        end
    end
    local fields = 0
    for i in ipairs(plays) do
        if core[i] and not fieldOf[i] then
            fields = fields + 1
            fieldOf[i] = fields
            local queue, head = { i }, 1
            while queue[head] do
                local a = queue[head]
                head = head + 1
                for j, q in ipairs(plays) do
                    if core[j] and not fieldOf[j] and near(plays[a], q) then
                        fieldOf[j] = fields
                        queue[#queue + 1] = j
                    end
                end
            end
        end
    end
    -- Everything else near a core joins that core's field: the first core it is near, by order.
    for i, p in ipairs(plays) do
        if not fieldOf[i] then
            for j, q in ipairs(plays) do
                if core[j] and near(p, q) then fieldOf[i] = fieldOf[j]; break end
            end
        end
    end

    local byKey, order = {}, {}
    local legs, lastLeg = 0, nil
    for i, play in ipairs(plays) do
        local key
        if fieldOf[i] then
            key, lastLeg = "field:" .. fieldOf[i], nil
        else
            -- A path leg runs until the character reaches a field or changes map.
            if not lastLeg or lastLeg.map ~= play.map then
                legs = legs + 1
                lastLeg = { key = "path:" .. legs, map = play.map }
            end
            key = lastLeg.key
        end
        play.group = key
        local g = byKey[key]
        if not g then
            g = { key = key, map = play.map, field = fieldOf[i], open = fieldOf[i] == nil, plays = {}, kinds = {},
                  subzones = {}, fences = {}, seconds = 0, first = play.t0 }
            byKey[key] = g
            order[#order + 1] = g
        end
        g.plays[#g.plays + 1] = play.n
        g.kinds[play.kind] = (g.kinds[play.kind] or 0) + 1
        g.seconds = g.seconds + play.seconds
        if play.subzone ~= "" then g.subzones[play.subzone] = (g.subzones[play.subzone] or 0) + 1 end
        if play.fence then g.fences[play.fence] = (g.fences[play.fence] or 0) + 1 end
    end
    for _, g in ipairs(order) do
        -- Named after the subzone most of its plays were in, as the minimap told the player.
        local best, most = nil, 0
        for name, n in pairs(g.subzones) do if n > most or (n == most and name < best) then best, most = name, n end end
        g.name = best
        -- The fence most of its plays were inside, and how many.
        local fence, inside = nil, 0
        for id, n in pairs(g.fences) do if n > inside or (n == inside and id < fence) then fence, inside = id, n end end
        g.fence, g.fenceInside = fence, inside
        g.subzones, g.fences = nil, nil
        -- Where its badge goes: the middle of its plays.
        local x, y = 0, 0
        for _, n in ipairs(g.plays) do
            local p = plays[n]
            x, y = x + p.x, y + p.y
        end
        g.x, g.y = x / #g.plays, y / #g.plays
    end
    return order
end

if ns then ns.Plays = Plays end
return Plays
