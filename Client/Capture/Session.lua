-- Wires episode nesting and position sampling to WoW events.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema, Coords = GBA.Schema, GBA.Coords
local episodes, sampler, buffer, vitals, subzone = ns.episodes, ns.sampler, ns.buffer, ns.vitals, ns.subzone

-- Health and power as whole percentages, plus whether we are fighting. Sampled on the
-- same ticker as position so a replay has both series on one timeline.
local function recordVitals(now)
    local maxHealth = UnitHealthMax("player")
    if not maxHealth or maxHealth <= 0 then return end

    local healthPct = math.floor(UnitHealth("player") / maxHealth * 100 + 0.5)
    local powerPct
    local maxPower = UnitPowerMax("player")
    if maxPower and maxPower > 0 then
        powerPct = math.floor(UnitPower("player") / maxPower * 100 + 0.5)
    end

    local inCombat = UnitAffectingCombat("player") and 1 or 0
    if not vitals:offer(healthPct, powerPct, inCombat, now) then return end

    local values = Schema.toArray(Schema.factType.vitals, {
        healthPct = healthPct, powerPct = powerPct, inCombat = inCombat,
    })
    buffer:add(Schema.factType.vitals, values, episodes:current(), now)
end

local function playerPosition()
    local mapID, isInstance = ns.resolveMapID()
    if not mapID or isInstance then return mapID end

    local position = C_Map and C_Map.GetPlayerMapPosition
        and C_Map.GetPlayerMapPosition(mapID, "player")
    if not position then return mapID end

    local x, y = position:GetXY()
    return mapID, x, y
end

local function zoneContext()
    local inInstance = IsInInstance and IsInInstance() or false
    return {
        isInstance = inInstance and true or false,
        groupSize = math.max(1, GetNumGroupMembers and GetNumGroupMembers() or 1),
    }
end

-- A closed leg is the time spent on one map. For an instance that is the run itself.
local function recordLeg(leg)
    if not leg or not leg.mapID or not leg.duration then return end

    local values = Schema.toArray(Schema.factType.zone_leg, {
        mapID = leg.mapID,
        duration = leg.duration,
        isInstance = leg.isInstance and 1 or 0,
        groupSize = leg.groupSize,
    })
    buffer:add(Schema.factType.zone_leg, values, {
        sessionID = leg.sessionID,
        legID = leg.legID,
        groupID = leg.groupID,
    }, leg.endedAt)
end

-- Completed fights were accumulating in memory and vanishing at logout.
local function drainEncounters()
    for _, fight in ipairs(episodes:drainCompleted()) do
        local values = Schema.toArray(Schema.factType.encounter, {
            mapID = fight.mapID,
            duration = fight.duration,
            bossID = fight.bossID,
            deaths = fight.deaths or 0,
        })
        buffer:add(Schema.factType.encounter, values, {
            sessionID = fight.sessionID,
            legID = fight.legID,
            encounterID = fight.encounterID,
            groupID = fight.groupID,
        }, fight.endedAt)
    end
end

ns.drainEncounters = drainEncounters

-- Everything still open, for logout and submission.
function ns.closeOpenEpisodes()
    local now = time()
    episodes:endEncounter(now)
    drainEncounters()
    recordLeg(episodes:closeLeg(now))
end

local function recordPosition()
    local now = time()
    recordVitals(now)

    local mapID, x, y = playerPosition()
    if not mapID then return end
    -- Track the zone even when coordinates are unavailable, so episode legs stay correct
    -- inside instances where only the map is known.
    local _, changed, closed = episodes:setZone(mapID, now, zoneContext())
    if changed then recordLeg(closed) end
    if not x or not y or (x == 0 and y == 0) then return end

    local coord = Coords.pack(x, y)
    -- Publish every successful reading, not just the ones the sampler keeps, so a kill a
    -- moment later has a fresh position to fall back on.
    ns.notePosition(mapID, coord, now)

    if not sampler:offer(mapID, x, y, now) then return end

    local values = Schema.toArray(Schema.factType.position, { mapID = mapID, coord = coord })
    buffer:add(Schema.factType.position, values, episodes:current(), now)
end

-- The minimap's place name, when it changes (Subzone.lua decides). Placed where the character
-- is now, or where they were a moment ago if the map does not answer this instant.
local function recordSubzone(now)
    local mapID, x, y = playerPosition()
    -- For a moment after login the game knows neither the map nor the place; seen in game as a
    -- row with no map and an empty name, two seconds before the real one. Wait for the next
    -- change event instead, which comes as soon as the place is known.
    if not mapID then return end
    local name = GetSubZoneText and GetSubZoneText()
    if not subzone:offer(name) then return end

    local coord = (x and y and not (x == 0 and y == 0)) and Coords.pack(x, y) or nil
    local last = ns.lastPosition
    if not coord and last and (not mapID or last.mapID == mapID)
        and now - (last.ts or 0) <= ns.POSITION_FALLBACK_SECONDS then
        mapID, coord = last.mapID, last.coord
    end

    local values = Schema.toArray(Schema.factType.subzone, { mapID = mapID, coord = coord, name = name })
    buffer:add(Schema.factType.subzone, values, episodes:current(), now)
end

-- Blow by blow in fights (schema 24; spec 2026-09-27-blow-by-blow-fights-design.md) --------------

-- The gear worn, slot by slot, as last written; a fight writes only what changed since.
local worn = {}
local GEAR_SLOTS = 19

local function recordGearSlot(slot, now)
    local item = GetInventoryItemID and GetInventoryItemID("player", slot) or nil
    item = item or 0
    if worn[slot] == item then return end
    worn[slot] = item
    local values = Schema.toArray(Schema.factType.gear, {
        slot = slot, itemID = item,
    })
    buffer:add(Schema.factType.gear, values, episodes:current(), now)
end

local function recordGear(now)
    for slot = 1, GEAR_SLOTS do recordGearSlot(slot, now) end
end

-- The target and its health, on change.
local lastTarget, lastTargetHealth
local function recordTarget(now)
    local guid = UnitExists and UnitExists("target") and UnitGUID("target") or nil
    local npc = guid and ns.Blows and ns.Blows.npcOf(guid) or 0
    local max = npc > 0 and UnitHealthMax("target") or 0
    local health = max > 0 and math.floor(UnitHealth("target") / max * 100 + 0.5) or nil
    -- Compared by GUID: a second mob of the same kind at the same health is a new target.
    if guid == lastTarget and health == lastTargetHealth then return end
    lastTarget, lastTargetHealth = guid, health
    if npc == 0 then return end
    local current = episodes:current()
    local values = Schema.toArray(Schema.factType.target, {
        npcID = npc, healthPct = health,
        mob = ns.mobs and ns.mobs:number(guid, current.sessionID) or nil,
    })
    buffer:add(Schema.factType.target, values, current, now)
end

-- Every half second in a fight: where the character stands, which way they face, whether they
-- are moving. The normal sampler keeps doing its own thing alongside.
local function recordPose(now)
    local mapID, x, y = playerPosition()
    if not mapID or not x or not y or (x == 0 and y == 0) then return end
    local speed = GetUnitSpeed and GetUnitSpeed("player") or 0
    local values = Schema.toArray(Schema.factType.pose, {
        mapID = mapID, coord = Coords.pack(x, y), facing = ns.Blows.mapFacing(GetPlayerFacing and GetPlayerFacing()),
        moving = speed > 0 and 1 or 0,
    })
    buffer:add(Schema.factType.pose, values, episodes:current(), now)
end

local fighting = false
local function inFight()
    if not fighting then return end
    local now = time()
    recordPose(now)
    recordTarget(now)
end

-- A session ends when the player is in a different zone, as well as at a login or reload
-- (docs/fix-plan.md, DEC-18, amending DEC-12). Never while flying: a flight path crosses zones
-- without the player being in any of them, so the new session starts when they land, and only
-- if the zone they land in is a different one. Nor in the middle of a fight, which would cut one
-- fight across two sessions; it waits for the fight to end. Zones, not sub-zones or the smaller
-- maps inside a zone (ZoneQuests' zoneOf walks up to the zone); a dungeon counts as a zone.
local sessionZone = nil       -- the zone the current session is in
local splitWaiting = false    -- a zone change came while flying or fighting

local function zoneNow()
    local map = playerPosition()
    if map == nil then return nil end
    return ns.zoneOf and ns.zoneOf(map) or map
end

local function onTaxi()
    return UnitOnTaxi and UnitOnTaxi("player") and true or false
end

-- Ends the current session and starts one in the zone the player is in now: the last zone visit
-- is closed and recorded under the old session, then the new one gets its own.
local function startZoneSession(now)
    splitWaiting = false
    local closed = episodes:closeLeg(now)
    if closed then recordLeg(closed) end
    local sessionID = episodes:startSession(now)
    if ns.noteSessionContext then ns.noteSessionContext(sessionID) end
    episodes:setZone(playerPosition(), now, zoneContext())
    recordSubzone(now)
    sessionZone = zoneNow()
end

-- Whether the zone change just seen starts a session now. When it has to wait (flying,
-- fighting) it is remembered, and the landing or the end of the fight looks again.
local function splitsNow()
    local zone = zoneNow()
    if zone == nil or sessionZone == nil or zone == sessionZone then
        splitWaiting = false
        return false
    end
    if onTaxi() or fighting then
        splitWaiting = true
        return false
    end
    return true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("PLAYER_CONTROL_GAINED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function(_, event)
    local now = time()

    if event == "PLAYER_LOGIN" then
        local sessionID = episodes:startSession(now)
        -- Capture who is observing now, not at submission time.
        if ns.noteSessionContext then ns.noteSessionContext(sessionID) end
        -- The saved setting was restored on ADDON_LOADED, which fires before this.
        local preset = ns.config.replay and "replay" or "normal"
        sampler:configure(preset)
        vitals:configure(preset)
        episodes:setZone(playerPosition(), now, zoneContext())
        recordSubzone(now)
        sessionZone = zoneNow()

        -- BigWigs supersedes the generic combat label with the actual boss. Registered
        -- here because the loader only exists once every addon has loaded.
        GBA.spokes:call("BigWigs", "registerBossCallbacks", ns, function(_, module)
            local name = type(module) == "table" and module.displayName or nil
            local bossID = type(module) == "table"
                and (module.journalId or module.engageId) or nil
            episodes:labelEncounter(name or "boss", bossID)
        end)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if splitsNow() then
            startZoneSession(now)
        else
            local _, changed, closed = episodes:setZone(playerPosition(), now, zoneContext())
            if changed then recordLeg(closed) end
            recordSubzone(now)
        end

    elseif event == "PLAYER_CONTROL_GAINED" then
        -- Landed from a flight path: a different zone from the session's starts a new one.
        if splitWaiting and splitsNow() then startZoneSession(now) end

    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        recordSubzone(now)

    elseif event == "PLAYER_REGEN_DISABLED" then
        episodes:beginEncounter(now)
        -- A fight is sampled finely: health and power on a 3-point change, the gear and target.
        fighting = true
        if not ns.config.replay then vitals:configure("replay") end
        recordGear(now)
        recordTarget(now)

    elseif event == "PLAYER_REGEN_ENABLED" then
        fighting = false
        if not ns.config.replay then vitals:configure("normal") end
        episodes:endEncounter(now)
        drainEncounters()
        -- A zone crossed mid-fight: the new session starts now the fight is over.
        if splitWaiting and splitsNow() then startZoneSession(now) end

    elseif event == "PLAYER_TARGET_CHANGED" then
        if fighting then recordTarget(now) end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- A swap mid-fight; out of a fight the next pull's snapshot catches it.
        if fighting then recordGear(now) end
    end
end)

-- Polled every second; the sampler decides which readings are worth keeping. Polling is
-- cheap, and replay mode needs a second-resolution path.
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(1, recordPosition)
    C_Timer.NewTicker(0.5, inFight)
end

