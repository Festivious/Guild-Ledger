-- The hard quest list's vocabulary and its counting. Pure, no WoW API use.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md.
--
-- Officers' offers have no requirement language, on purpose: a person reads the claim and
-- judges it (Reward.lua explains why). The hard list is the one place the addon itself decides
-- whether something is done, so it gets a vocabulary of its own - and a CLOSED one. We write
-- the kinds, ship them, and add one only when a real guild idea needs it. Nobody types them.
--
-- A quest is a zone, a level range, steps and pay. Steps are done in order: a step counts only
-- what happened after the step before it was finished, which is how "cook the cakes, then the
-- claws" is written. Progress only ever counts up. Deaths never touch it.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Schema, Coords, Reward
if ns then
    Schema, Coords, Reward = ns.Schema, ns.Coords, ns.Reward
else
    Schema, Coords, Reward = require("Schema"), require("Coords"), require("Reward")
end

local HardQuest = {}

local F = Schema.factType

-- Permanent codes, like fact codes: never renumbered, never reused. The catalog names kinds in
-- words; a code is what travels when a kind has to.
HardQuest.kind = {
    kill   = 1,
    obtain = 2,
    mail   = 3,
    gather = 4,
    craft  = 5,
    skill  = 6,
    visit  = 7,
    sell   = 8,   -- reserved: the Auction House step builds it
}

-- What this version can count. sell has a code but no counting yet, so a quest using it is
-- refused rather than shown and never finished.
local BUILT = {
    kill = true, obtain = true, mail = true, gather = true, craft = true, skill = true, visit = true,
}

HardQuest.gatherKind = { herb = 1, mine = 2, skin = 3 }

HardQuest.MAX_LEVEL = 60
HardQuest.MAX_SKILL = 300

local function posInt(v)
    return type(v) == "number" and v >= 1 and v == math.floor(v)
end

local function idList(list)
    if type(list) ~= "table" or #list == 0 then return false end
    for _, id in ipairs(list) do
        if not posInt(id) then return false end
    end
    return true
end

-- Checks one step. Returns true, or false and why.
local function validStep(step, isLast)
    if type(step) ~= "table" then return false, "a step must be a table" end
    local kind = step.kind
    if HardQuest.kind[kind] == nil then return false, "unknown kind " .. tostring(kind) end
    if not BUILT[kind] then return false, kind .. " is not built yet" end

    if kind == "kill" then
        -- Either one set of mobs and a count, or groups that each need their own count
        -- ("24 Prowlers and 15 bears" is not "39 of either").
        if step.groups ~= nil then
            if type(step.groups) ~= "table" or #step.groups == 0 then return false, "kill groups are empty" end
            for _, group in ipairs(step.groups) do
                if type(group) ~= "table" or not idList(group.npcs) or not posInt(group.count) then
                    return false, "each kill group needs npcs and a count"
                end
            end
        else
            if not idList(step.npcs) then return false, "a kill step needs npcs" end
            if not posInt(step.count) then return false, "a kill step needs a count" end
        end
    elseif kind == "obtain" or kind == "mail" then
        if not idList(step.items) then return false, "an " .. kind .. " step needs items" end
        if not posInt(step.count) then return false, "an " .. kind .. " step needs a count" end
        -- A mail step is claimed by posting the items, so nothing can come after it.
        if kind == "mail" and not isLast then return false, "mail must be the last step" end
    elseif kind == "gather" then
        if HardQuest.gatherKind[step.skill] == nil then return false, "gather needs herb, mine or skin" end
        if step.items ~= nil and not idList(step.items) then return false, "gather items must be ids" end
        if not posInt(step.count) then return false, "a gather step needs a count" end
    elseif kind == "craft" then
        if type(step.items) ~= "table" or #step.items == 0 then return false, "a craft step needs items" end
        for _, pair in ipairs(step.items) do
            if type(pair) ~= "table" or not posInt(pair[1]) or not posInt(pair[2]) then
                return false, "craft items are { itemID, count } pairs"
            end
        end
    elseif kind == "skill" then
        if not posInt(step.skillLine) then return false, "a skill step needs a skillLine" end
        if not posInt(step.value) or step.value > HardQuest.MAX_SKILL then
            return false, "a skill step needs a value up to " .. HardQuest.MAX_SKILL
        end
    elseif kind == "visit" then
        local at = step.at
        if type(at) ~= "table" or type(at[1]) ~= "number" or type(at[2]) ~= "number"
            or at[1] < 0 or at[1] > 100 or at[2] < 0 or at[2] > 100 then
            return false, "a visit step needs map coordinates from 0 to 100"
        end
        if type(step.radius) ~= "number" or step.radius <= 0 then return false, "a visit step needs a radius" end
    end
    return true
end

-- Checks one catalog entry. Returns the entry, or nil and why.
function HardQuest.validate(entry)
    if type(entry) ~= "table" then return nil, "not a quest" end
    if not posInt(entry.id) then return nil, "a quest needs an id" end
    local name = "quest " .. entry.id

    if not posInt(entry.zone) then return nil, name .. " needs a zone" end
    if entry.turnIn ~= nil and not posInt(entry.turnIn) then return nil, name .. "'s turn-in must be a map" end
    if type(entry.title) ~= "string" or entry.title == "" then return nil, name .. " needs a title" end
    if #entry.title > Reward.MAX_TITLE then return nil, name .. "'s title is too long" end
    if entry.note ~= nil and (type(entry.note) ~= "string" or #entry.note > Reward.MAX_BODY) then
        return nil, name .. "'s note is too long"
    end

    local levels = entry.levels
    if type(levels) ~= "table" or not posInt(levels[1]) or not posInt(levels[2])
        or levels[2] > HardQuest.MAX_LEVEL or levels[1] > levels[2] then
        return nil, name .. " needs a level range, low to high"
    end

    if type(entry.steps) ~= "table" or #entry.steps == 0 then return nil, name .. " needs steps" end
    for i, step in ipairs(entry.steps) do
        local ok, why = validStep(step, i == #entry.steps)
        if not ok then return nil, name .. ", step " .. i .. ": " .. why end
    end

    local pay = entry.pay
    if type(pay) ~= "table" or not (posInt(pay.copper) or posInt(pay.bagSlots)) then
        return nil, name .. " needs pay: coin or a bag"
    end
    return entry
end

-- Where a quest is turned in: its own zone unless it names another, which is how a quest leads the
-- player on to the next zone along the levelling path.
function HardQuest.turnInZone(entry)
    return entry.turnIn or entry.zone
end

-- Checks a whole catalog. Returns true, or false and every problem found.
function HardQuest.validateCatalog(list)
    local problems, seen = {}, {}
    for _, entry in ipairs(type(list) == "table" and list or {}) do
        local ok, why = HardQuest.validate(entry)
        if not ok then problems[#problems + 1] = why end
        if type(entry) == "table" and entry.id ~= nil then
            if seen[entry.id] then problems[#problems + 1] = "quest " .. tostring(entry.id) .. " is listed twice" end
            seen[entry.id] = true
        end
    end
    return #problems == 0, problems
end

-- Counting ----------------------------------------------------------------------------------

local function set(list)
    local s = {}
    for _, id in ipairs(list or {}) do s[id] = true end
    return s
end

-- Is this fact from inside the quest's zone and level range? A fact that carries no map or
-- no level is not held to that rule (a skill-up happens wherever the player is).
local function inBounds(entry, v, zoneOf)
    if v.mapID ~= nil and (zoneOf and zoneOf(v.mapID) or v.mapID) ~= entry.zone then return false end
    local level = v.observerLevel
    if level ~= nil and (level < entry.levels[1] or level > entry.levels[2]) then return false end
    return true
end

-- The separate counts inside one step, when it has them: a craft step's items, a kill step's
-- groups. Each slot is capped at its own count, so a surplus in one never covers another.
local function slots(step)
    if step.kind == "craft" then
        local s = {}
        for i, pair in ipairs(step.items) do s[i] = pair[2] end
        return s
    elseif step.kind == "kill" and step.groups then
        local s = {}
        for i, group in ipairs(step.groups) do s[i] = group.count end
        return s
    end
    return nil
end

-- How much one fact adds to one step, or nil when it has nothing to do with it. A step with
-- slots also says which slot.
local function contribution(entry, step, fact, cache)
    local v, code = fact.v or {}, fact.code
    local kind = step.kind

    if kind == "kill" then
        if code ~= F.kill then return nil end
        if v.participated ~= Schema.participation.participated then return nil end
        if step.groups then
            if not cache.groups then
                cache.groups = {}
                for i, group in ipairs(step.groups) do cache.groups[i] = set(group.npcs) end
            end
            for i, members in ipairs(cache.groups) do
                if members[v.npcID] then return 1, i end
            end
            return nil
        end
        cache.npcs = cache.npcs or set(step.npcs)
        if not cache.npcs[v.npcID] then return nil end
        return 1
    elseif kind == "obtain" then
        if code ~= F.loot_drop then return nil end
        cache.items = cache.items or set(step.items)
        if not cache.items[v.itemID] then return nil end
        -- What the player took, not what dropped: an item left on the corpse is not obtained. A
        -- drop recorded before received existed counts as what dropped.
        if v.received ~= nil then return v.received end
        return v.quantity or 1
    elseif kind == "gather" then
        if code ~= F.gathered or v.kind ~= HardQuest.gatherKind[step.skill] then return nil end
        if step.items then
            cache.items = cache.items or set(step.items)
            if not cache.items[v.itemID] then return nil end
            return v.quantity or 1
        end
        -- Nodes, not items: a vein that gave ore and a stone is still one vein.
        if v.lootIndex ~= 1 then return nil end
        return 1
    elseif kind == "craft" then
        if code ~= F.crafted then return nil end
        for i, pair in ipairs(step.items) do
            if pair[1] == v.itemID then return v.quantity or 1, i end
        end
        return nil
    elseif kind == "skill" then
        if code ~= F.skill_up or v.skillLine ~= step.skillLine then return nil end
        return v.toValue or 0
    elseif kind == "visit" then
        if code ~= F.position or type(v.coord) ~= "number" then return nil end
        local x, y = Coords.unpack(v.coord)
        local dx, dy = x * 100 - step.at[1], y * 100 - step.at[2]
        if dx * dx + dy * dy > step.radius * step.radius then return nil end
        return 1
    end
    return nil
end

local function need(step)
    local s = slots(step)
    if s then
        local n = 0
        for _, count in ipairs(s) do n = n + count end
        return n
    elseif step.kind == "skill" then
        return step.value
    elseif step.kind == "visit" then
        return 1
    end
    return step.count
end

-- Progress on one quest.
--
--   facts   a list of { code, v = named values, time }, in the order they happened
--   opts    since  = when the quest was switched on (earlier facts don't count);
--           held   = itemID -> count in bags, for a mail step;
--           zoneOf = mapID -> the zone it lies in. The client records the most specific map,
--                    so a cave or a building can carry its own id; without this, a map
--                    counts only as itself.
--
-- Returns { steps = { { have, need, doneAt } }, done, current }. `have` never passes `need`,
-- `doneAt` is the index of the fact that finished the step, and `current` is the first step
-- not yet done.
function HardQuest.progress(entry, facts, opts)
    opts = opts or {}
    facts = facts or {}
    local since = opts.since
    local out, start = { steps = {}, done = false }, 0

    for i, step in ipairs(entry.steps) do
        local total = need(step)
        local have, doneAt = 0, nil

        if step.kind == "mail" then
            -- Held, not happened: what is in the bags right now.
            for _, itemID in ipairs(step.items) do have = have + ((opts.held or {})[itemID] or 0) end
            if have >= total and (i == 1 or out.steps[i - 1].doneAt) then doneAt = start end
        elseif start ~= nil then
            local cache, perSlot, caps = {}, {}, slots(step)
            for index = start + 1, #facts do
                local fact = facts[index]
                if type(fact) == "table" and (since == nil or (fact.time or 0) >= since)
                    and inBounds(entry, fact.v or {}, opts.zoneOf) then
                    local amount, slot = contribution(entry, step, fact, cache)
                    if amount then
                        if caps then
                            perSlot[slot] = (perSlot[slot] or 0) + amount
                            have = 0
                            for n, cap in ipairs(caps) do have = have + math.min(perSlot[n] or 0, cap) end
                        elseif step.kind == "skill" then
                            have = math.max(have, amount)
                        else
                            have = have + amount
                        end
                        if have >= total then doneAt = index; break end
                    end
                end
            end
        end

        out.steps[i] = { have = math.min(have, total), need = total, doneAt = doneAt }
        if not doneAt and not out.current then out.current = i end
        start = doneAt
    end

    out.done = out.current == nil
    return out
end

-- The evidence for a finished quest, for its claim: the officer's addon recounts it with
-- progress() and shows "verified 200 / 200" (hard-quest spec, Part 3). Every fact up to the one
-- that finished the last step, that is in bounds and adds to some step: counting just these gives
-- what counting everything gave, because each step still starts after the one before it.
-- Returns their indices into facts, in order, and the player's own progress.
function HardQuest.evidence(entry, facts, opts)
    opts = opts or {}
    facts = facts or {}
    local p = HardQuest.progress(entry, facts, opts)
    local last = 0
    for _, s in ipairs(p.steps) do
        if s.doneAt and s.doneAt > last then last = s.doneAt end
    end
    local caches, keep = {}, {}
    for i = 1, #entry.steps do caches[i] = {} end
    for index = 1, last do
        local fact = facts[index]
        if type(fact) == "table" and (opts.since == nil or (fact.time or 0) >= opts.since)
            and inBounds(entry, fact.v or {}, opts.zoneOf) then
            for i, step in ipairs(entry.steps) do
                if step.kind ~= "mail" and contribution(entry, step, fact, caches[i]) then
                    keep[#keep + 1] = index
                    break
                end
            end
        end
    end
    return keep, p
end

-- Becoming an offer -------------------------------------------------------------------------

-- The fields Reward.new takes for this quest, so it shows in the existing list, detail page and
-- claim flow. `base` supplies what belongs to the switch itself: issuer, counter or id, and any
-- revision, expiry or signature. The quest's own rules always come from the local catalog; the
-- offer is how it is shown and claimed.
function HardQuest.toOfferFields(entry, base)
    local f = {}
    for k, v in pairs(base or {}) do f[k] = v end

    f.hardID = entry.id
    f.title = entry.title
    f.body = entry.note
    f.attach = Reward.attach.none
    f.requires = { { kind = Reward.requireKind.level, min = entry.levels[1], max = entry.levels[2] } }

    if entry.pay.copper then
        f.gives = { { money = entry.pay.copper } }
    else
        f.gives = { { text = "a " .. entry.pay.bagSlots .. "-slot bag" } }
    end

    local last = entry.steps[#entry.steps]
    if last.kind == "mail" then
        f.wants = {}
        for _, itemID in ipairs(last.items) do
            f.wants[#f.wants + 1] = { itemID = itemID, quantity = last.count }
        end
    else
        f.wants = {}
    end
    return f
end

if ns then ns.HardQuest = HardQuest end
return HardQuest
