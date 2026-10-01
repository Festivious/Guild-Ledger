-- The kill/loot denominator. Pure state machine: no WoW API use, so every correctness
-- property below is testable outside the game.
--
-- Three loot outcomes, not two:
--   unobserved - the corpse was never opened. A valid kill fact, but it says NOTHING
--                about drop rates. Counting these as zero-drops would deflate every rate
--                in the corpus, which is worse than missing data because it looks real.
--   observed   - the window opened and we saw its contents, including genuinely empty.
--                These, and only these, form the drop-rate denominator.
--
-- Corpses are keyed by full GUID, not npcID: the trailing GUID field is the spawn
-- instance, so two of the same mob are distinct corpses.
local _, ns = ...
if ns and ns.standDown then return end

local KillLog = {}
KillLog.__index = KillLog

KillLog.UNOBSERVED = "unobserved"
KillLog.OBSERVED = "observed"

local DEFAULTS = {
    ringSize = 30,   -- recent kills kept for fallback attribution (MobInfo2 uses 30)
    lootTTL = 3600,  -- how long a looted corpse is remembered, to block re-counting
}

function KillLog.new(opts)
    opts = opts or {}
    return setmetatable({
        ringSize = opts.ringSize or DEFAULTS.ringSize,
        lootTTL = opts.lootTTL or DEFAULTS.lootTTL,
        kills = {},        -- guid -> kill record
        ring = {},         -- recent guids, oldest first
        lootedAt = {},     -- guid -> timestamp the corpse was opened
        damaged = {},      -- guid -> timestamp we last damaged it
        open = nil,        -- guid of the loot window currently open
    }, KillLog)
end

-- Records that we hurt this unit, so its death can be told apart from a bystander kill.
function KillLog:markDamaged(guid, ts)
    if type(guid) ~= "string" then return end
    self.damaged[guid] = ts
end

function KillLog:didParticipate(guid)
    return self.damaged[guid] ~= nil
end

local function pushRing(self, guid)
    self.ring[#self.ring + 1] = guid
    while #self.ring > self.ringSize do
        table.remove(self.ring, 1)
    end
end

function KillLog:recordKill(guid, npcID, ts, context)
    if type(guid) ~= "string" or type(npcID) ~= "number" then return nil end
    if self.kills[guid] then return self.kills[guid] end

    local kill = {
        guid = guid,
        npcID = npcID,
        ts = ts,
        lootState = KillLog.UNOBSERVED,
        participated = self.damaged[guid] ~= nil,
        items = {},
        context = context or {},
    }
    self.damaged[guid] = nil
    self.kills[guid] = kill
    pushRing(self, guid)
    return kill
end

-- Returns the kill record if this open should be counted, or nil if it must be ignored.
-- Reopening a corpse (skinning, a second look) must never re-count its contents.
function KillLog:beginLoot(guid, ts)
    if type(guid) ~= "string" then return nil, "no corpse guid" end
    if self.lootedAt[guid] then return nil, "corpse already looted" end

    local kill = self.kills[guid]
    if not kill then return nil, "no recorded kill for this corpse" end

    self.open = guid
    self.lootedAt[guid] = ts
    kill.lootState = KillLog.OBSERVED
    return kill
end

function KillLog:addItem(itemID, quantity)
    if not self.open then return nil, "no loot window open" end
    local kill = self.kills[self.open]
    if not kill then return nil, "open window has no kill record" end
    kill.items[#kill.items + 1] = { itemID = itemID, quantity = quantity or 1 }
    return kill
end

-- What the player actually took from a looted corpse, once its window has settled (LootRules):
-- `received` is itemID -> count from Blizzard's receive lines. Each drop gets its share, 0 for an
-- item left behind; one item in two stacks shares its count between them, never double. What
-- DROPPED is unchanged - that is still what the window held.
function KillLog:markReceived(guid, received)
    local kill = type(guid) == "string" and self.kills[guid]
    if not kill or kill.lootState ~= KillLog.OBSERVED then return nil end
    local left = {}
    for itemID, count in pairs(received or {}) do left[itemID] = count end
    for _, item in ipairs(kill.items) do
        local take = math.min(item.quantity or 1, left[item.itemID] or 0)
        item.received = take
        if left[item.itemID] then left[item.itemID] = left[item.itemID] - take end
    end
    return kill
end

function KillLog:endLoot()
    self.open = nil
end

-- GetLootSourceInfo is unreliable under AoE loot, so when the source GUID is unusable we
-- fall back to the most recent kill that has not yet been looted.
function KillLog:mostRecentUnlooted()
    for i = #self.ring, 1, -1 do
        local guid = self.ring[i]
        if not self.lootedAt[guid] and self.kills[guid] then
            return guid
        end
    end
    return nil
end

function KillLog:resolveCorpse(sourceGUID)
    if sourceGUID and self.kills[sourceGUID] and not self.lootedAt[sourceGUID] then
        return sourceGUID
    end
    return self:mostRecentUnlooted()
end

function KillLog:prune(now)
    for guid, ts in pairs(self.lootedAt) do
        if now - ts > self.lootTTL then
            self.lootedAt[guid] = nil
        end
    end
    -- Damage marks only matter until the unit dies. Anything we hurt but that never died
    -- nearby (it fled, we did, it despawned) is dropped so the table cannot grow forever.
    for guid, ts in pairs(self.damaged) do
        if now - ts > 600 then
            self.damaged[guid] = nil
        end
    end
end

-- Counts for the drop-rate denominator. Unobserved kills are deliberately excluded.
function KillLog:stats()
    local total, observed, empty, withLoot, participated = 0, 0, 0, 0, 0
    for _, kill in pairs(self.kills) do
        total = total + 1
        if kill.participated then participated = participated + 1 end
        if kill.lootState == KillLog.OBSERVED then
            observed = observed + 1
            if #kill.items == 0 then empty = empty + 1 else withLoot = withLoot + 1 end
        end
    end
    return {
        kills = total,
        observed = observed,
        unobserved = total - observed,
        emptyLoots = empty,
        lootedWithItems = withLoot,
        participated = participated,
        bystander = total - participated,
    }
end

function KillLog:allKills()
    local out = {}
    for _, kill in pairs(self.kills) do
        out[#out + 1] = kill
    end
    return out
end

-- A kill's outcome is not final the moment it dies: an unlooted corpse can still be
-- opened until it despawns. Harvesting early would freeze the wrong loot state, so a
-- kill is only released once it has had longer than a corpse lifetime to settle.
KillLog.SETTLE_SECONDS = 300

-- Removes and returns settled kills. The currently open loot window is never harvested.
function KillLog:harvest(now, settleSeconds)
    settleSeconds = settleSeconds or KillLog.SETTLE_SECONDS

    local harvested = {}
    for guid, kill in pairs(self.kills) do
        if guid ~= self.open and (now - kill.ts) >= settleSeconds then
            harvested[#harvested + 1] = kill
            self.kills[guid] = nil
        end
    end
    return harvested
end

-- Everything except the open window, for logout and submission.
function KillLog:harvestAll()
    local harvested = {}
    for guid, kill in pairs(self.kills) do
        if guid ~= self.open then
            harvested[#harvested + 1] = kill
            self.kills[guid] = nil
        end
    end
    return harvested
end

if ns then ns.KillLog = KillLog end
return KillLog
