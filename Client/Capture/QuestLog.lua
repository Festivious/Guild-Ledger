-- Quest lifecycle bookkeeping. Pure, no WoW API use.
--
-- QUEST_REMOVED fires whenever a quest leaves the log, and handing one in removes it.
-- Recording every removal as an abandonment therefore made each completed quest ALSO
-- look abandoned: the abandonment count was exactly the completion count, and the true
-- figure - usually zero - could never be recovered from the corpus. A real session showed
-- quests 783 and 5261 turned in and immediately "abandoned" one second later.
--
-- QUEST_TURNED_IN fires first, so a turn-in claims the removal that follows it. The claim
-- is held per questID rather than by timestamp, because the two events are not reliably
-- in the same second.
local _, ns = ...
if ns and ns.standDown then return end

local QuestLog = {}
QuestLog.__index = QuestLog

-- How long a turn-in may wait for its removal. Generous next to the observed gap of 0-1
-- seconds, and still far too short for a player to accept and abandon the same quest
-- again inside the window.
QuestLog.CLAIM_SECONDS = 30

function QuestLog.new()
    return setmetatable({ pending = {} }, QuestLog)
end

function QuestLog:turnedIn(questID, ts)
    if questID == nil then return end
    self.pending[questID] = ts or 0
end

-- Accepting a quest clears any stale claim: whatever the earlier turn-in was waiting for,
-- it is not this removal.
function QuestLog:accepted(questID)
    if questID == nil then return end
    self.pending[questID] = nil
end

-- Answers whether a removal is a real abandonment. Consumes the claim either way, so one
-- turn-in can only ever absorb one removal.
function QuestLog:isAbandonment(questID, ts)
    if questID == nil then return false end

    local claimedAt = self.pending[questID]
    if claimedAt == nil then return true end
    self.pending[questID] = nil

    -- A claim older than the window is stale: the quest was handed in long ago and has
    -- since been taken and dropped, which is a genuine abandonment.
    if ts ~= nil and ts - claimedAt > QuestLog.CLAIM_SECONDS then return true end
    return false
end

function QuestLog:pendingCount()
    local n = 0
    for _ in pairs(self.pending) do n = n + 1 end
    return n
end

if ns then ns.QuestLog = QuestLog end
return QuestLog
