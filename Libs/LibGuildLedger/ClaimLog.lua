-- The player's own record of what they claimed. Pure, no WoW API use.
--
-- Before this, a claim left no trace on the player's side once it had gone: the reward
-- showed Claim again, and the only sign of it was the locked session in the outbox, filed
-- by transfer id rather than by reward. This is the other half of that: one entry per claim,
-- found by the reward it was for, carrying enough to be shown on its own.
--
-- An entry copies the offer's title and issuer, because the offer can be edited, removed or
-- expire while the claim is still being dealt with, and the player should still be able to
-- see what they claimed and from whom.
--
-- Where the data is (locked, delivered, safe) and which key letters have gone are NOT kept
-- here. The outbox owns those, under the claim's transferID; the view reads both, so the two
-- can never disagree.
--
-- The state is Reward.state: submitted when the claim has gone, and settled or declined once
-- the officer says so. The officer's side of that is not wired yet.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Reward
if ns then Reward = ns.Reward else Reward = require("Reward") end

local ClaimLog = {}
ClaimLog.__index = ClaimLog

-- Enough for a long time of claiming without letting saved data grow for ever. The oldest
-- go first.
ClaimLog.MAX = 200

local function trimmed(text, max)
    if type(text) ~= "string" then return nil end
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return nil end
    return #text > max and text:sub(1, max) or text
end

local function validState(state)
    return type(state) == "number" and Reward.stateName[state] ~= nil
end

-- One entry, from what the claim flow knows once the claim has gone. Returns nil, reason
-- for anything that could not be shown or found again.
function ClaimLog.entry(fields)
    if type(fields) ~= "table" then return nil, "not an entry" end
    if fields.rewardID == nil then return nil, "a claim needs a reward" end
    if type(fields.at) ~= "number" then return nil, "a claim needs a time" end

    local transferID = fields.transferID
    if not (type(transferID) == "string" and transferID:match("^%x+$") and #transferID <= 16) then
        transferID = nil
    end

    return {
        rewardID = fields.rewardID,
        title = trimmed(fields.title, Reward.MAX_TITLE) or "(untitled)",
        issuer = type(fields.issuer) == "string" and fields.issuer or nil,
        -- Which revision of the offer was claimed, so an edit made afterwards can be told apart.
        revision = type(fields.revision) == "number" and fields.revision or nil,
        at = fields.at,
        sending = Reward.entries(fields.sending),
        note = trimmed(fields.note, Reward.MAX_DETAIL),
        attach = Reward.attachName[fields.attach] and fields.attach or Reward.attach.none,
        transferID = transferID,
        state = validState(fields.state) and fields.state or Reward.state.submitted,
        -- When the state last changed, for "awarded two days ago".
        stateAt = type(fields.stateAt) == "number" and fields.stateAt or nil,
        -- An officer granted this character one more claim of the offer.
        requeued = fields.requeued == true or nil,
        -- Whether an officer has confirmed holding the claim message. Until then it is sent
        -- again to whichever officer is online. Absent means an entry from before this field,
        -- which was only recorded after a successful send.
        delivered = fields.delivered ~= false or nil,
        -- Whether an officer holds the claim ON DISK: it came back after their reload or login
        -- (docs/fix-plan.md, DEC-6). "Delivered" only stops the quick retries; until saved the
        -- claim is offered again at every check-in. Kept as false rather than nil, because a nil
        -- is not written to saved variables and would read back as an old entry: one from before
        -- this field, taken as saved once delivered, as it was then.
        saved = (fields.saved == true or (fields.saved == nil and fields.delivered ~= false)) or false,
        sessionID = type(fields.sessionID) == "number" and fields.sessionID or nil,
        -- The offer's other deciders still owed a letter about this claim: every decider is
        -- mailed the claim (docs/fix-plan.md, DEC-5). Resumed at each mailbox until none is left.
        lettersDue = Reward.readers(fields.lettersDue),
        -- A guild quest's evidence, kept only until an officer has the claim saved, so a resend
        -- carries it too; then dropped, so the save file does not keep it for good.
        evidence = Reward.evidence(fields.evidence),
    }
end

function ClaimLog.new()
    return setmetatable({ entries = {} }, ClaimLog)
end

-- Adds a claim. Oldest dropped past MAX.
function ClaimLog:record(fields)
    local entry, err = ClaimLog.entry(fields)
    if not entry then return nil, err end
    self.entries[#self.entries + 1] = entry
    while #self.entries > ClaimLog.MAX do table.remove(self.entries, 1) end
    return entry
end

-- The most recent claim against a reward, or nil if this character never claimed it.
function ClaimLog:latest(rewardID)
    for i = #self.entries, 1, -1 do
        if self.entries[i].rewardID == rewardID then return self.entries[i] end
    end
    return nil
end

-- The claim that sent a given locked session.
function ClaimLog:byTransfer(transferID)
    if transferID == nil then return nil end
    for i = #self.entries, 1, -1 do
        if self.entries[i].transferID == transferID then return self.entries[i] end
    end
    return nil
end

-- Newest first.
function ClaimLog:all()
    local out = {}
    for i = #self.entries, 1, -1 do out[#out + 1] = self.entries[i] end
    return out
end

function ClaimLog:count()
    return #self.entries
end

-- Moves the latest claim against a reward to a new state. For the officer's answer.
function ClaimLog:setState(rewardID, state, at)
    local entry = self:latest(rewardID)
    if not entry then return nil, "no claim for that reward" end
    if not validState(state) then return nil, "unknown state" end
    entry.state, entry.stateAt = state, type(at) == "number" and at or entry.stateAt
    return entry
end

-- Claims no officer has confirmed holding yet, oldest first.
function ClaimLog:undelivered()
    local out = {}
    for _, entry in ipairs(self.entries) do
        if not entry.delivered then out[#out + 1] = entry end
    end
    return out
end

-- Claims no officer has on disk yet, and still waiting on a decision, oldest first. A decision
-- means an officer had it, so a decided claim needs offering to nobody.
function ClaimLog:unsaved()
    local out = {}
    for _, entry in ipairs(self.entries) do
        if not entry.saved and entry.state == Reward.state.submitted then out[#out + 1] = entry end
    end
    return out
end

-- An officer confirmed holding the claim made at `at` against `rewardID`; with saved, holding it
-- on disk. Returns the entry, whether it is newly delivered, and whether it is newly saved.
function ClaimLog:markDelivered(rewardID, at, saved)
    for i = #self.entries, 1, -1 do
        local entry = self.entries[i]
        if entry.rewardID == rewardID and entry.at == at then
            local was, wasSaved = entry.delivered, entry.saved
            entry.delivered = true
            if saved then entry.saved, entry.evidence = true, nil end
            return entry, not was, (saved and not wasSaved) or false
        end
    end
    return nil
end

-- Letters still owed to other deciders, oldest claim first: { entry, to }.
function ClaimLog:lettersDue()
    local out = {}
    for _, entry in ipairs(self.entries) do
        for _, name in ipairs(entry.lettersDue or {}) do out[#out + 1] = { entry = entry, to = name } end
    end
    return out
end

-- The letter to `to` about the claim made at `at` against `rewardID` went.
function ClaimLog:letterSent(rewardID, at, to)
    for i = #self.entries, 1, -1 do
        local entry = self.entries[i]
        if entry.rewardID == rewardID and entry.at == at and entry.lettersDue then
            local left = {}
            for _, name in ipairs(entry.lettersDue) do if name ~= to then left[#left + 1] = name end end
            entry.lettersDue = #left > 0 and left or nil
            return true
        end
    end
    return false
end

-- Whether this character's claim stands in the way of claiming the offer: claimed, and not
-- requeued by an officer since. One claim per offer per character.
function ClaimLog:blocks(rewardID)
    local entry = self:latest(rewardID)
    return entry ~= nil and not entry.requeued
end

-- An officer's notice (OfficerClaims): a decision on one claim, found by reward and the
-- claim's time, or a requeue of the offer. Returns the entry changed, or nil, reason.
function ClaimLog:apply(notice, now)
    if type(notice) ~= "table" or notice.rewardID == nil then return nil, "not a notice" end
    if notice.kind == "requeue" then
        local entry = self:latest(notice.rewardID)
        if not entry then return nil, "no claim for that offer" end
        entry.requeued = true
        return entry
    end
    if notice.kind == "state" then
        for i = #self.entries, 1, -1 do
            local entry = self.entries[i]
            if entry.rewardID == notice.rewardID and entry.at == notice.at then
                if not validState(notice.state) then return nil, "unknown state" end
                entry.state, entry.stateAt = notice.state, now
                -- Decided, so an officer had it: nothing left to offer again.
                entry.delivered, entry.saved, entry.evidence = true, true, nil
                return entry
            end
        end
        return nil, "no such claim"
    end
    return nil, "unknown notice"
end

-- For saved variables: the entries as they are.
function ClaimLog:export()
    return self.entries
end

-- Restores from saved variables. Each entry is revalidated; the file has been on disk.
function ClaimLog:load(saved)
    self.entries = {}
    if type(saved) ~= "table" then return 0 end
    for _, fields in ipairs(saved) do
        local entry = ClaimLog.entry(fields)
        if entry then self.entries[#self.entries + 1] = entry end
    end
    while #self.entries > ClaimLog.MAX do table.remove(self.entries, 1) end
    return #self.entries
end

if ns then ns.ClaimLog = ClaimLog end
return ClaimLog
