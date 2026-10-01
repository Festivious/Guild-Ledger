-- WoW event wiring for the kill/loot denominator. Deliberately thin: all decisions live
-- in KillLog, which is pure and tested. This file only translates events into calls.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local GUID, Coords, Schema = ns.GUID, GBA.Coords, GBA.Schema

local log = ns.killLog
local KillFacts, buffer, episodes = ns.KillFacts, ns.buffer, ns.episodes
local deathLog = ns.deathLog

-- Moves settled kills out of the in-memory log and into the fact buffer, which is what
-- gets persisted and submitted. Without this the denominator never leaves memory.
function ns.flushKills(everything)
    local now = time()
    local kills = everything and log:harvestAll() or log:harvest(now)
    if #kills == 0 then return 0 end
    return KillFacts.flush(kills, buffer, episodes:current(), now)
end

local function livePosition()
    local mapID, isInstance = ns.resolveMapID()
    -- Inside an instance there is a map but never a coordinate, so do not even ask.
    if not mapID or isInstance or not (C_Map and C_Map.GetPlayerMapPosition) then
        return mapID
    end

    local position = C_Map.GetPlayerMapPosition(mapID, "player")
    if not position then return mapID end

    local x, y = position:GetXY()
    if not x or not y then return mapID end

    -- Zero is truthy in Lua, and some maps answer 0,0 rather than nil when they have no
    -- real position to give. The exact map origin is never where a player stands, so
    -- treat it as no position rather than recording a spawn at the corner of the map.
    if x == 0 and y == 0 then return mapID end

    return mapID, Coords.pack(x, y)
end

local function playerContext()
    local now = time()
    local mapID, coord = livePosition()
    local stats = ns.positionStats

    if mapID and coord then
        stats.live = stats.live + 1
        ns.notePosition(mapID, coord, now)
    else
        local last = ns.lastPosition
        -- Only borrow a position from the SAME map. Instances report no coordinates, so
        -- without this check the first kills inside a dungeon would inherit the outdoor
        -- coordinates of the zone just left and claim those mobs spawned there.
        if last and last.mapID == mapID
            and (now - last.ts) <= ns.POSITION_FALLBACK_SECONDS then
            coord = last.coord
            stats.fallback = stats.fallback + 1
        else
            stats.none = stats.none + 1
        end
    end

    return {
        mapID = mapID,
        coord = coord,
        observerLevel = UnitLevel("player"),
        groupSize = math.max(1, GetNumGroupMembers and GetNumGroupMembers() or 1),
    }
end

-- Shared with the looting record (Looting.lua), so a node is placed the way a kill is.
ns.playerContext = playerContext

local playerGUID

-- Each creature dealt with this session, numbered (schema 25). Shared with Session.lua's target.
local mobs = ns.Blows.newMobs()
ns.mobs = mobs

-- Anything we or our pet aimed at a unit counts as taking part: damage, a debuff, a
-- crowd control. The distinction that matters is participant versus bystander, not how
-- the mob was engaged.
local function isOurs(sourceGUID)
    if not sourceGUID then return false end
    if sourceGUID == playerGUID then return true end
    local pet = UnitGUID("pet")
    return pet ~= nil and sourceGUID == pet
end

-- UNIT_DIED says only that you died, never what did it. The killing blow has to be
-- observed beforehand, so incoming damage is remembered as it lands.
local function noteIncomingDamage(subevent, sourceGUID, now)
    local info

    if subevent == "ENVIRONMENTAL_DAMAGE" then
        local environmentType, amount = select(12, CombatLogGetCurrentEventInfo())
        info = {
            environment = Schema.environmentByName[tostring(environmentType):upper()]
                or Schema.environment.none,
            amount = amount,
        }

    elseif subevent == "SWING_DAMAGE" then
        local amount = select(12, CombatLogGetCurrentEventInfo())
        info = { npcID = GUID.npcID(sourceGUID), amount = amount }

    elseif subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE"
        or subevent == "RANGE_DAMAGE" then
        local spellID, _, _, amount = select(12, CombatLogGetCurrentEventInfo())
        info = { npcID = GUID.npcID(sourceGUID), spellID = spellID, amount = amount }

    else
        return
    end

    deathLog:noteDamage(info, now)
end

local function onPlayerDeath(now)
    local context = playerContext()
    local death = deathLog:recordDeath(now, context)
    episodes:noteDeath()

    local values = Schema.toArray(Schema.factType.player_death, {
        mapID = context.mapID,
        coord = context.coord,
        observerLevel = context.observerLevel,
        groupSize = context.groupSize,
        killerNpcID = death.killerNpcID,
        killerSpellID = death.killerSpellID,
        environment = death.environment or Schema.environment.none,
    })
    buffer:add(Schema.factType.player_death, values, episodes:current(), now)

    GBA.Print("|cffff4040death recorded|r at map " .. tostring(context.mapID) ..
        (death.killerNpcID and (", killed by npc " .. death.killerNpcID) or "") ..
        ((death.environment and death.environment ~= Schema.environment.none)
            and (", environmental type " .. death.environment) or ""))
end

-- Blow by blow (schema 24), in fights only: every hit, miss and heal either way, and buffs and
-- debuffs on the character or their target. Blows.lua decides what an event means.
local function recordBlow(subevent, sourceGUID, destGUID, now, ...)
    local current = episodes:current()
    if not current.encounterID and not UnitAffectingCombat("player") then return end
    local kind, b = ns.Blows.read(subevent, sourceGUID, destGUID, playerGUID, UnitGUID("target"), ...)
    if kind == "blow" then
        local values = Schema.toArray(Schema.factType.blow, {
            dir = b.dir, spellID = b.spellID, npcID = b.npcID, amount = b.amount, result = b.result,
            absorbed = b.absorbed, overkill = b.overkill, mob = mobs:number(b.guid, current.sessionID),
        })
        buffer:add(Schema.factType.blow, values, current, now)
    elseif kind == "aura" then
        local values = Schema.toArray(Schema.factType.aura, {
            who = b.who, spellID = b.spellID, change = b.change, npcID = b.npcID,
            mob = mobs:number(b.guid, current.sessionID),
        })
        buffer:add(Schema.factType.aura, values, current, now)
    end
end

local function onCombatLogEvent()
    local _, subevent, _, sourceGUID, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
    local now = time()
    if ns.Blows then recordBlow(subevent, sourceGUID, destGUID, now, select(12, CombatLogGetCurrentEventInfo())) end

    if subevent == "UNIT_DIED" then
        if destGUID == playerGUID then
            onPlayerDeath(now)
            return
        end
        local npcID = GUID.npcID(destGUID)
        if not npcID then return end -- other players' deaths are not our kills
        local context = playerContext()
        -- The session and fight it died in, kept until the kill is written (KillFacts.flush).
        context.chain = episodes:current()
        context.mob = mobs:known(destGUID, context.chain.sessionID)
        log:recordKill(destGUID, npcID, now, context)
        return
    end

    if destGUID == playerGUID then
        noteIncomingDamage(subevent, sourceGUID, now)
    end

    -- Individual casts with a time, which Details' per-fight aggregates cannot give.
    -- Consumables are casts too, so eating, drinking, potions and bandages land here and
    -- are identifiable by spell at read time.
    if subevent == "SPELL_CAST_SUCCESS" and sourceGUID == playerGUID then
        local spellID = select(12, CombatLogGetCurrentEventInfo())
        if spellID then
            local context = playerContext()
            local current = episodes:current()
            local values = Schema.toArray(Schema.factType.spell_cast, {
                spellID = spellID,
                targetNpcID = GUID.npcID(destGUID),
                mapID = context.mapID,
                coord = context.coord,
                targetMob = mobs:number(destGUID, current.sessionID),
            })
            buffer:add(Schema.factType.spell_cast, values, current, now)
        end
    end

    -- UNIT_DIED fires for every creature death in range, so participation has to be
    -- observed before the death rather than inferred from it.
    if isOurs(sourceGUID) and destGUID ~= sourceGUID then
        log:markDamaged(destGUID, now)
    end
end

-- itemID from an item link, e.g. |cff9d9d9d|Hitem:3299::::::::20:257|h[Fractured Canine]|h|r
local function itemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local function sourceGUIDForSlot(slot)
    if not GetLootSourceInfo then return nil end
    local ok, guid = pcall(GetLootSourceInfo, slot)
    if not ok then return nil end
    return guid
end

local function onLootOpened()
    -- A skinned corpse's leather is gathering, not the mob's drop: counted as a drop it would
    -- inflate every drop rate for that mob. Looting.lua records it as gathering instead.
    if ns.isSkinning and ns.isSkinning() then return end

    local slots = GetNumLootItems and GetNumLootItems() or 0

    -- Attribution: prefer the corpse GUID the API reports, fall back to the most recent
    -- unlooted kill. GetLootSourceInfo is documented as unreliable under AoE loot.
    local sourceGUID = slots > 0 and sourceGUIDForSlot(1) or nil
    local corpse = log:resolveCorpse(sourceGUID)
    if not corpse then return end

    local kill = log:beginLoot(corpse, time())
    if not kill then return end -- reopened corpse, or no matching kill

    for slot = 1, slots do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local itemID = itemIDFromLink(link)
        if itemID then
            local _, _, quantity = GetLootSlotInfo(slot)
            log:addItem(itemID, quantity or 1)
        end
    end
end

local function onLootClosed()
    log:endLoot()
    log:prune(time())
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        onCombatLogEvent()
    elseif event == "LOOT_OPENED" then
        onLootOpened()
    elseif event == "LOOT_CLOSED" then
        onLootClosed()
    end
end)

-- Settled kills are swept periodically so a long session does not hold every corpse in
-- memory, and so a crash loses only the last few minutes rather than everything.
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(60, function() ns.flushKills(false) end)
end

