-- Episode nesting: session > zone-leg > encounter. Pure state machine, no WoW API use.
--
-- This is the "when" layer. Every fact is stamped with the episode chain it happened in,
-- so a record can be walked back up to the fight, the zone visit and the play session it
-- belonged to. Without it the corpus is a flat pile of events with no narrative.
local _, ns = ...
if ns and ns.standDown then return end

local Episodes = {}
Episodes.__index = Episodes

-- Details discards fights under about five seconds; matching that keeps our encounter
-- boundaries comparable with the combat data we snapshot from it.
local MIN_ENCOUNTER_SECONDS = 5

function Episodes.new(opts)
    opts = opts or {}
    return setmetatable({
        minEncounter = opts.minEncounter or MIN_ENCOUNTER_SECONDS,
        sessionID = nil,
        legID = nil,
        encounterID = nil,
        groupID = nil,
        mapID = nil,
        nextLeg = 1,
        nextEncounter = 1,
        legStart = nil,
        legIsInstance = false,
        legGroupSize = 1,
        encounterStart = nil,
        encounterLabel = nil,
        encounterBossID = nil,
        completed = {},
    }, Episodes)
end

-- The roster the facts that follow belong to. Solo is still a group of one, so every
-- fact can be sliced by composition rather than only the grouped ones.
function Episodes:setGroup(groupID)
    self.groupID = groupID
    return self.groupID
end

function Episodes:startSession(ts)
    self.sessionID = ts
    self.legID = nil
    self.encounterID = nil
    self.mapID = nil
    self.nextLeg = 1
    self.nextEncounter = 1
    return self.sessionID
end

-- A new leg only begins on an actual zone change; repeated reports of the same zone are
-- ignored so a position poll does not shred the session into thousands of legs.
--
-- Returns legID, changed, and the leg that just closed. For an instance that closed leg
-- IS the dungeon run: entering to leaving, wipes and walking included, which is what
-- people mean when they ask how long a run took.
function Episodes:setZone(mapID, ts, context)
    if not self.sessionID then self:startSession(ts) end
    if mapID == nil or mapID == self.mapID then return self.legID, false end

    -- Leaving a zone ends any fight in progress; a fight cannot span two zones.
    if self.encounterID then self:endEncounter(ts) end

    local closed = self:closeLeg(ts)

    context = context or {}
    self.mapID = mapID
    self.legID = self.nextLeg
    self.nextLeg = self.nextLeg + 1
    self.legStart = ts
    self.legIsInstance = context.isInstance and true or false
    self.legGroupSize = context.groupSize or 1

    return self.legID, true, closed
end

-- Closes the current leg and returns its record, or nil when there was none.
function Episodes:closeLeg(ts)
    if not self.legID or not self.legStart then return nil end

    local record = {
        sessionID = self.sessionID,
        legID = self.legID,
        groupID = self.groupID,
        mapID = self.mapID,
        startedAt = self.legStart,
        endedAt = ts,
        duration = ts - self.legStart,
        isInstance = self.legIsInstance,
        groupSize = self.legGroupSize,
    }
    self.legStart = nil
    return record
end

function Episodes:beginEncounter(ts, label)
    if not self.sessionID then self:startSession(ts) end
    if self.encounterID then return self.encounterID, false end

    self.encounterID = self.nextEncounter
    self.nextEncounter = self.nextEncounter + 1
    self.encounterStart = ts
    self.encounterLabel = label
    self.encounterDeaths = 0
    return self.encounterID, true
end

-- Returns the completed encounter, or nil when it was too short to be meaningful.
function Episodes:endEncounter(ts)
    if not self.encounterID then return nil end

    local duration = (ts or 0) - (self.encounterStart or 0)
    local record
    if duration >= self.minEncounter then
        record = {
            sessionID = self.sessionID,
            legID = self.legID,
            encounterID = self.encounterID,
            groupID = self.groupID,
            mapID = self.mapID,
            label = self.encounterLabel,
            bossID = self.encounterBossID,
            deaths = self.encounterDeaths or 0,
            startedAt = self.encounterStart,
            endedAt = ts,
            duration = duration,
        }
        self.completed[#self.completed + 1] = record
    end

    self.encounterID = nil
    self.encounterStart = nil
    self.encounterLabel = nil
    self.encounterBossID = nil
    self.encounterDeaths = 0
    return record
end

-- Hands over completed encounters and forgets them, so they can be turned into facts
-- instead of accumulating in memory and vanishing at logout.
function Episodes:drainCompleted()
    local completed = self.completed
    self.completed = {}
    return completed
end

-- Deaths during a fight are part of what made it hard, so the encounter counts them
-- rather than reporting a hardcoded zero.
function Episodes:noteDeath()
    self.encounterDeaths = (self.encounterDeaths or 0) + 1
    return self.encounterDeaths
end

-- A boss label from BigWigs supersedes a generic combat label already in progress.
function Episodes:labelEncounter(label, bossID)
    if self.encounterID then
        self.encounterLabel = label
        self.encounterBossID = bossID
    end
    return self.encounterLabel
end

function Episodes:current()
    return {
        sessionID = self.sessionID,
        legID = self.legID,
        encounterID = self.encounterID,
        groupID = self.groupID,
        mapID = self.mapID,
    }
end

-- Stamps a fact with the episode chain it occurred in.
function Episodes:stamp(fact)
    fact = fact or {}
    fact.sessionID = self.sessionID
    fact.legID = self.legID
    fact.encounterID = self.encounterID
    fact.groupID = self.groupID
    return fact
end

function Episodes:completedEncounters()
    return self.completed
end

if ns then ns.Episodes = Episodes end
return Episodes
