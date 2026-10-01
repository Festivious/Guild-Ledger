-- Zone quests and the quest log: the guild's hard-list quests, the way the game does quests.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 2 ("A quest's life").
-- Accepted at a mailbox in the quest's own zone, kept in the quest log, turned in at a mailbox in
-- the zone it names. Officers switch quests on with offers that carry a hardID; what counts toward
-- a quest always comes from this client's own catalog, looked up by that id, never from the
-- offer's text. Progress is counted here, from this character's own capture, from the moment the
-- quest was accepted, and nothing leaves the client until the player turns it in.
local _, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local HardQuest, HardList, Schema, Reward = GBA.HardQuest, GBA.HardList, GBA.Schema, GBA.Reward
local F = Schema.factType

local byID = {}
for _, entry in ipairs(HardList or {}) do byID[entry.id] = entry end

-- This character's quest log: what is accepted, since when, what is turned in. Saved by Status.lua
-- (GuildLedgerDB.hardLog), which restores it on ADDON_LOADED, after this file has made it.
ns.hardLog = GBA.HardLog.new()

-- The zone a map lies in. The client records the most specific map it can name, so a cave or a
-- town may carry its own id; quests are per zone, so this walks up to the zone. Cached, since a
-- map's parent never changes.
local ZONE_TYPE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local zoneCache = {}

local function zoneOf(mapID)
    if type(mapID) ~= "number" then return mapID end
    local cached = zoneCache[mapID]
    if cached then return cached end
    local zone, id = mapID, mapID
    for _ = 1, 6 do
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
        if not info then break end
        if info.mapType == ZONE_TYPE then zone = id; break end
        if not info.parentMapID or info.parentMapID == 0 then break end
        id = info.parentMapID
    end
    zoneCache[mapID] = zone
    return zone
end
ns.zoneOf = zoneOf

local function currentZone()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    return zoneOf(map)
end
ns.currentZone = currentZone

-- The switches this client holds, one per quest. Two officers may both switch the same quest on;
-- the earlier switch is the one that stands, so the list never flickers between them.
function ns.hardSwitches()
    local best = {}
    local now = time()
    for _, reward in ipairs(ns.rewardCatalog and ns.rewardCatalog:list() or {}) do
        local entry = reward.hardID and byID[reward.hardID]
        if entry and not Reward.hasExpired(reward, now) then
            local held = best[entry.id]
            if not held or (reward.issuedAt or 0) < (held.reward.issuedAt or 0) then
                best[entry.id] = { reward = reward, entry = entry }
            end
        end
    end
    local out = {}
    for _, row in pairs(best) do out[#out + 1] = row end
    table.sort(out, function(a, b) return a.entry.id < b.entry.id end)
    return out
end

local function liveSwitches()
    local out = {}
    for _, sw in ipairs(ns.hardSwitches()) do out[sw.entry.id] = sw.reward end
    return out
end

-- The facts counting needs, in the order they happened. Only the kinds a quest can count, and only
-- from the earliest accept on, so a long buffer is walked once and mostly skipped.
local COUNTED = { [F.kill] = true, [F.loot_drop] = true, [F.gathered] = true, [F.crafted] = true,
    [F.skill_up] = true }

local function factsSince(since, withPositions)
    local out = {}
    -- The pool and the archive both: a session leaving the pool must not take quest progress
    -- with it (docs/fix-plan.md, DEC-10).
    local function take(e)
        if (COUNTED[e.code] or (withPositions and e.code == F.position))
            and type(e.ts) == "number" and e.ts >= since then
            out[#out + 1] = { code = e.code, v = Schema.fromArray(e.code, e.values), time = e.ts, e = e }
        end
    end
    if ns.eachRecord then
        ns.eachRecord(take)
    else
        for _, e in ipairs(ns.buffer and ns.buffer.entries or {}) do take(e) end
    end
    return out
end

local function held(entry)
    local last = entry.steps[#entry.steps]
    if last.kind ~= "mail" or type(GetItemCount) ~= "function" then return nil end
    local out = {}
    for _, itemID in ipairs(last.items) do out[itemID] = GetItemCount(itemID) or 0 end
    return out
end

-- The evidence a turn-in carries (hard-quest spec, Part 3): the recorded facts that counted, in
-- the shape shared data travels in, so the officer's addon can recount them and, once the claim
-- is awarded, add them to the guild's analytics. Nil when the quest is not in the log.
function ns.questEvidence(hardID)
    local entry = byID[hardID]
    local since = entry and ns.hardLog:acceptedAt(hardID)
    if not since then return nil end
    local positions = false
    for _, step in ipairs(entry.steps) do
        if step.kind == "visit" then positions = true end
    end
    local facts = factsSince(since, positions)
    local keep = HardQuest.evidence(entry, facts, { since = since, held = held(entry), zoneOf = zoneOf })
    local out, sessions = {}, {}
    for _, i in ipairs(keep) do
        local e = facts[i].e
        out[e.code] = out[e.code] or {}
        table.insert(out[e.code], Schema.withChain(e.code, e.values, e))
        if e.sessionID and ns.sessions and ns.sessions[e.sessionID] then sessions[e.sessionID] = ns.sessions[e.sessionID] end
    end
    return { acceptedAt = since, facts = out, sessions = sessions }
end

-- What a quest looks like in a list when no officer's switch for it is live any more (a quest
-- accepted before its switch was removed stays in the log, like a real quest).
local function displayReward(entry)
    return Reward.new(HardQuest.toOfferFields(entry, { id = "hard#" .. entry.id, issuer = "Guild" }))
end

-- Progress for rows that are in the log, each counted from its own accept time. The buffer is
-- walked once, from the earliest accept.
local function withProgress(rows)
    local since, positions = nil, false
    for _, row in ipairs(rows) do
        if row.acceptedAt then
            if since == nil or row.acceptedAt < since then since = row.acceptedAt end
            for _, step in ipairs(row.entry.steps) do
                if step.kind == "visit" then positions = true end
            end
        end
    end
    if since == nil then return rows end
    local facts = factsSince(since, positions)
    for _, row in ipairs(rows) do
        if row.acceptedAt then
            row.progress = HardQuest.progress(row.entry, facts,
                { since = row.acceptedAt, held = held(row.entry), zoneOf = zoneOf })
        end
    end
    return rows
end

-- A quest in the log, as a row. `here` is the zone of the mailbox being looked at, if any.
local function logRow(entry, switches, here)
    local turnInZone = HardQuest.turnInZone(entry)
    return {
        entry = entry, state = "active",
        reward = switches[entry.id] or displayReward(entry),
        switched = switches[entry.id] ~= nil,
        acceptedAt = ns.hardLog:acceptedAt(entry.id),
        unlocked = true, unmet = {},
        turnInZone = turnInZone,
        turnInHere = here ~= nil and turnInZone == here,
    }
end

local ORDER = { turnIn = 1, active = 2, offer = 3 }

-- The guild quests at a mailbox in `zone` (default: where the player stands), for a character of
-- `level`. Three kinds of row, in this order:
--   turnIn  in the log, done, and this is where it is turned in
--   active  in the log, from this zone or turned in here, still going
--   offer   switched on for this zone, not yet accepted or turned in; a quest the character has
--           outgrown is left out, one they are not old enough for is shown locked
function ns.zoneQuests(zone, level)
    zone = zone or currentZone()
    level = level or UnitLevel("player")
    local actor = ns.actor and ns.actor() or { level = level, now = GBA.now() }
    local switches = liveSwitches()

    local rows = {}
    for _, id in ipairs(ns.hardLog:accepted()) do
        local entry = byID[id]
        if entry and (entry.zone == zone or HardQuest.turnInZone(entry) == zone) then
            rows[#rows + 1] = logRow(entry, switches, zone)
        end
    end
    withProgress(rows)
    for _, row in ipairs(rows) do
        -- Turned in to the officer whose switch is live; with none, it waits in the log.
        if row.progress and row.progress.done and row.turnInHere and row.switched then row.state = "turnIn" end
    end

    for _, sw in ipairs(ns.hardSwitches()) do
        local entry = sw.entry
        if entry.zone == zone and ns.hardLog:status(entry.id) == nil
            and type(level) == "number" and level <= entry.levels[2] then
            local unlocked, unmet = Reward.gate(sw.reward, actor)
            rows[#rows + 1] = { entry = entry, state = "offer", reward = sw.reward, switched = true,
                unlocked = unlocked, unmet = unmet }
        end
    end

    table.sort(rows, function(a, b)
        if a.state ~= b.state then return ORDER[a.state] < ORDER[b.state] end
        return a.entry.id < b.entry.id
    end)
    return rows
end

-- The whole quest log, grouped by the zone each quest belongs to, zones in the catalog's order.
-- Returns { { zone = uiMapID, rows = { ... } }, ... }.
function ns.guildQuestLog()
    local switches = liveSwitches()
    local rows = {}
    for _, id in ipairs(ns.hardLog:accepted()) do
        if byID[id] then rows[#rows + 1] = logRow(byID[id], switches, nil) end
    end
    withProgress(rows)

    local groups, index = {}, {}
    for _, entry in ipairs(HardList or {}) do
        if not index[entry.zone] then
            index[entry.zone] = #groups + 1
            groups[#groups + 1] = { zone = entry.zone, rows = {} }
        end
    end
    for _, row in ipairs(rows) do
        table.insert(groups[index[row.entry.zone]].rows, row)
    end
    local out = {}
    for _, group in ipairs(groups) do
        if #group.rows > 0 then out[#out + 1] = group end
    end
    return out
end

-- Accepting: at a mailbox in the quest's own zone, while an officer's switch for it is live, and
-- only if the character meets its level range. Returns true, or nil and why.
function ns.acceptHard(id)
    local entry = byID[id]
    if not entry then return nil, "no such guild quest" end
    if ns.isAtMailbox and not ns.isAtMailbox() then return nil, "guild quests are accepted at a mailbox" end
    if currentZone() ~= entry.zone then return nil, "this quest is accepted in its own zone" end
    local switch = liveSwitches()[id]
    if not switch then return nil, "no officer has this quest switched on" end
    local unlocked, unmet = Reward.gate(switch, ns.actor and ns.actor() or {})
    if not unlocked then return nil, unmet[1] or "you cannot take this quest yet" end
    return ns.hardLog:accept(id, time())
end

function ns.abandonHard(id)
    return ns.hardLog:abandon(id)
end

-- Where one quest stands for this character, at the mailbox the player is at:
-- "offer", "active", "turnIn" or "turnedIn", and its row when it has one.
function ns.hardState(id)
    local status = ns.hardLog:status(id)
    if status == "turnedIn" then return "turnedIn" end
    for _, row in ipairs(ns.zoneQuests()) do
        if row.entry.id == id then return row.state, row end
    end
    return status == "accepted" and "active" or "offer"
end

-- The mailbox a quest is turned in at, by name, for the log and the pins.
function ns.turnInPlace(entry)
    local box = HardList.mailboxes and HardList.mailboxes[HardQuest.turnInZone(entry)]
    return box and box[3] or "its mailbox"
end

-- One line for a row, the way the list, the log and the tracker show it.
function ns.describeProgress(row)
    if row.state == "offer" then
        return row.unlocked and "New - open it to accept" or (row.unmet[1] or "locked")
    end
    local p = row.progress
    if not p then return "" end
    if p.done then
        if row.turnInHere and not row.switched then return "Ready - no officer is offering it right now" end
        if row.turnInHere then return "Turn in here" end
        return "Ready - turn in at " .. ns.turnInPlace(row.entry)
    end
    local step = p.steps[p.current]
    local text = step.have .. " / " .. step.need
    if #p.steps > 1 then text = "step " .. p.current .. " of " .. #p.steps .. ": " .. text end
    return text
end

