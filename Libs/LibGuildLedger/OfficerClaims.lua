-- The officer's side of claims: what arrived, what was decided, and who still has to be told.
-- Pure, no WoW API use.
--
-- A claim is received, then awarded or declined at the mailbox. Either decision is sent back to
-- the player by the transport layer so their own record (ClaimLog) changes too; until the
-- player acknowledges it, the decision stays on the "to tell" list and is sent again whenever
-- they are online. That is how a decision made while the player is offline still lands.
--
-- The awarded list is what stops a repeat. It holds, per offer, how many times each character
-- has been awarded it, and how many extra claims an officer has granted them (a requeue, for
-- a repeatable bounty). A claim from someone already awarded, with no requeue left, is still
-- held - the officer decides - but marked as a repeat. A player who edits their own saved data
-- to claim again is caught here, as long as this officer sees the claim.
--
-- Kept small on purpose. A decided claim is dropped once the player knows and a grace period
-- has passed; the awarded list for an offer is dropped when the offer is gone, because nobody
-- can claim a removed or expired offer anyway.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Reward
if ns then Reward = ns.Reward else Reward = require("Reward") end

local OfficerClaims = {}
OfficerClaims.__index = OfficerClaims

-- How long a decided, told claim is kept for the officer to look back on.
OfficerClaims.GRACE = 30 * 86400

local function short(name)
    if type(name) ~= "string" then return nil end
    return name:match("^([^%-]+)") or name
end

-- One claim's id: who claimed, and when. The player's ClaimLog finds its own entry by the
-- reward and this time, so the pair is what a decision is addressed with.
function OfficerClaims.idOf(from, at)
    from = short(from)
    if not from or type(at) ~= "number" then return nil end
    return from .. "@" .. at
end

function OfficerClaims.new()
    return setmetatable({ records = {}, awarded = {}, allowance = {}, notices = {}, relays = {},
        carried = {}, done = {}, log = {} }, OfficerClaims)
end

-- Claims this officer holds for another officer ------------------------------------------
--
-- A claim goes to the officer who posted the offer when they are online, and otherwise to any
-- online officer, who holds it and passes it on when the poster logs in. The player can be
-- offline by then; the officers share it among themselves. Decided by the user, 2026-09-24.

-- Holds a claim for `issuer`. Receiving the same claim twice holds it once.
function OfficerClaims:holdFor(claim, from, issuer, now)
    if type(claim) ~= "table" or claim.rewardID == nil then return nil, "not a claim" end
    local at = type(claim.at) == "number" and claim.at or now
    local id = OfficerClaims.idOf(from, at)
    issuer = short(issuer)
    if not id or not issuer then return nil, "a claim to hold needs a sender, a time and an officer" end
    if not self.relays[id] then
        self.relays[id] = { id = id, claim = claim, from = short(from), issuer = issuer, heldAt = now, saved = false }
    end
    return self.relays[id]
end

-- Durability (docs/fix-plan.md, DEC-6) ------------------------------------------------------
--
-- WoW writes saved variables only at a logout or a reload. A claim this officer received is in
-- memory until then, so it is `saved = false`; everything load() restores came back from disk and
-- is saved. Another officer can also say a copy is saved (claimSaved), because one officer's disk
-- is enough: the claim is passed to every officer online the moment it arrives, and whichever of
-- them next reloads or logs out saves it for the guild.

-- A claim held here, as received or as held for another officer.
function OfficerClaims:find(id)
    return self.records[id] or self.relays[id]
end

-- Another officer has this claim on disk. Returns true when that is news here.
function OfficerClaims:markSaved(id)
    local r = self:find(id)
    if not r or r.saved then return false end
    r.saved = true
    return true
end

-- Claims still in play that are on some officer's disk: undecided ones received here, and every
-- one held for another officer. { id, from, rewardID, at }, oldest first.
function OfficerClaims:openSaved()
    local out = {}
    for id, r in pairs(self.records) do
        if r.saved and r.state == Reward.state.submitted then
            out[#out + 1] = { id = id, from = r.from, rewardID = r.rewardID, at = r.at }
        end
    end
    for id, r in pairs(self.relays) do
        if r.saved then
            out[#out + 1] = { id = id, from = r.from, rewardID = r.claim.rewardID, at = r.claim.at }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- Claims held for one officer, oldest first.
function OfficerClaims:heldFor(issuer)
    issuer = short(issuer)
    local out = {}
    for _, r in pairs(self.relays) do
        if not issuer or r.issuer == issuer then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- The officer it was held for has it now.
function OfficerClaims:passedOn(id)
    local had = self.relays[id] ~= nil
    self.relays[id] = nil
    return had
end

local function count(t, rewardID, name)
    return (t[rewardID] and t[rewardID][name]) or 0
end

local function bump(t, rewardID, name, by)
    t[rewardID] = t[rewardID] or {}
    t[rewardID][name] = count(t, rewardID, name) + by
end

-- Whether this character may claim this offer again: never awarded, or granted a requeue
-- for each award beyond the first.
function OfficerClaims:mayClaim(rewardID, name)
    name = short(name)
    return count(self.awarded, rewardID, name) < 1 + count(self.allowance, rewardID, name)
end

-- Holds a claim that passed the receive checks. claim is Reward.claim's table; from is the
-- server-attested sender. Receiving the same claim twice returns the one already held.
function OfficerClaims:receive(claim, reward, from, now)
    if type(claim) ~= "table" or claim.rewardID == nil then return nil, "not a claim" end
    local at = type(claim.at) == "number" and claim.at or now
    local id = OfficerClaims.idOf(from, at)
    if not id then return nil, "a claim needs a sender and a time" end
    if self.records[id] then return self.records[id] end

    local name = short(from)
    local record = {
        id = id,
        rewardID = claim.rewardID,
        title = type(reward) == "table" and reward.title or nil,
        from = name,
        at = at,
        sending = claim.sending,
        note = claim.note,
        attach = claim.attach,
        transferID = claim.transferID,
        -- The offer's revision the player claimed against, when their client says (E6).
        revision = claim.revision,
        -- A guild quest's evidence, recounted on arrival and folded in once awarded; dropped
        -- when the claim is decided.
        evidence = claim.evidence,
        state = Reward.state.submitted,
        receivedAt = now,
        saved = false,
        -- Already awarded and not requeued: held, but the officer should know.
        repeated = not self:mayClaim(claim.rewardID, name) or nil,
    }
    self.records[id] = record
    -- A decision on it came back before it did (restore): applied now.
    local waiting = self.awaiting and self.awaiting[id]
    if waiting then
        self.awaiting[id] = nil
        if waiting.own then self:restore(waiting.notice) else self:adopt(waiting.notice) end
    end
    return record
end

function OfficerClaims:get(id)
    return self.records[id]
end

local function newestFirst(out)
    table.sort(out, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.id < b.id
    end)
    return out
end

-- Claims against one offer, newest first.
function OfficerClaims:forReward(rewardID)
    local out = {}
    for _, r in pairs(self.records) do
        if r.rewardID == rewardID then out[#out + 1] = r end
    end
    return newestFirst(out)
end

-- Claims still waiting on a decision, newest first.
function OfficerClaims:open()
    local out = {}
    for _, r in pairs(self.records) do
        if r.state == Reward.state.submitted then out[#out + 1] = r end
    end
    return newestFirst(out)
end

function OfficerClaims:all()
    local out = {}
    for _, r in pairs(self.records) do out[#out + 1] = r end
    return newestFirst(out)
end

local function noticeKey(n) return n.to .. "|" .. tostring(n.rewardID) .. "|" .. n.kind .. "|" .. tostring(n.at) end

local function addNotice(self, notice)
    notice.key = noticeKey(notice)
    self.notices[notice.key] = notice
    return notice
end

-- Awards or declines a held claim, and queues telling the player. Awarding counts toward the
-- awarded list. A claim is decided once; deciding it again is refused.
function OfficerClaims:decide(id, state, now)
    local r = self.records[id]
    if not r then return nil, "no such claim" end
    if state ~= Reward.state.settled and state ~= Reward.state.declined then
        return nil, "a claim is awarded or declined"
    end
    if r.state ~= Reward.state.submitted then return nil, "that claim is already decided" end
    -- Checked again here, not only when the claim arrived: two claims from one player can both
    -- arrive before either is decided (one held by another officer and passed on late), and
    -- neither is a repeat on arrival. One award per player unless the offer is requeued for them.
    if state == Reward.state.settled and not self:mayClaim(r.rewardID, r.from) then
        return nil, r.from .. " was already awarded this offer; decline this claim, or requeue it for them first"
    end
    r.state, r.stateAt = state, now
    if state == Reward.state.settled then bump(self.awarded, r.rewardID, r.from, 1) end
    local notice = addNotice(self, { kind = "state", to = r.from, rewardID = r.rewardID, at = r.at, state = state })
    return r, notice
end

-- Grants one more claim of an offer to one character, and queues telling them. For someone
-- who claimed it and has nothing still waiting: after an award (a repeatable bounty) it adds
-- to their allowance; after a decline it only tells them, since a decline used nothing up.
function OfficerClaims:requeue(rewardID, name, now)
    name = short(name)
    if rewardID == nil or not name then return nil, "requeue needs an offer and a character" end
    local claimed = false
    for _, r in pairs(self.records) do
        if r.rewardID == rewardID and r.from == name then
            claimed = true
            if r.state == Reward.state.submitted then
                return nil, name .. " has a claim on it waiting on you"
            end
        end
    end
    if not claimed and self:mayClaim(rewardID, name) then
        return nil, name .. " has not claimed it"
    end
    if not self:mayClaim(rewardID, name) then bump(self.allowance, rewardID, name, 1) end
    return addNotice(self, { kind = "requeue", to = name, rewardID = rewardID, at = now })
end

-- Decisions and requeues the player has not acknowledged yet, for one player or everyone.
function OfficerClaims:untold(name)
    name = short(name)
    local out = {}
    for _, n in pairs(self.notices) do
        if not name or n.to == name then out[#out + 1] = n end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- The player acknowledged a notice.
function OfficerClaims:told(key)
    return self:delivered(key)
end

-- Signed decisions, carried and logged ----------------------------------------------------
--
-- A decision is signed by the officer who made it and shared with every online officer, so any
-- of them can deliver it to the player (the decider and the player may never be online
-- together) and every officer, the guild master included, keeps a log of who decided what, with
-- the signature as proof. Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md,
-- part B.

-- This officer's own notice, now signed: logged.
function OfficerClaims:signed(notice)
    if type(notice) ~= "table" or not notice.key or not notice.sig then return nil end
    self.log = self.log or {}
    self.log[notice.key] = notice
    return notice
end

-- Another officer's signed decision, checked by the caller: carried to the player and logged.
-- Nothing is carried once delivered, so a late copy does not start it all again.
function OfficerClaims:carry(notice)
    if type(notice) ~= "table" or type(notice.to) ~= "string" or notice.rewardID == nil
        or (notice.kind ~= "state" and notice.kind ~= "requeue") or not notice.sig then
        return nil, "not a signed decision"
    end
    notice.key = noticeKey(notice)
    self.log = self.log or {}
    self.log[notice.key] = notice
    if self.done[notice.key] then return nil, "already delivered" end
    if self.notices[notice.key] then return self.notices[notice.key] end
    self.carried[notice.key] = notice
    return notice
end

-- A signed decision applied to this officer's own records: the claim reads as decided and the
-- one-award rule counts it. Returns the claim (true for a requeue), or nil when nothing here
-- changes. A claim not held here yet waits for it, in memory: receive() applies it on arrival.
local function applyDecision(self, notice, own)
    if notice.kind == "state" then
        if notice.state ~= Reward.state.settled and notice.state ~= Reward.state.declined then return nil end
        local id = OfficerClaims.idOf(notice.to, notice.at)
        local r = self.records[id]
        if not r then
            self.awaiting = self.awaiting or {}
            self.awaiting[id] = { notice = notice, own = own }
            return nil
        end
        if r.state ~= Reward.state.submitted then return nil end
        r.state, r.stateAt = notice.state, notice.signedAt or r.receivedAt
        if notice.state == Reward.state.settled then bump(self.awarded, r.rewardID, r.from, 1) end
        return r
    elseif notice.kind == "requeue" then
        bump(self.allowance, notice.rewardID, short(notice.to), 1)
        return true
    end
    return nil
end

local function signedNotice(notice)
    return type(notice) == "table" and type(notice.to) == "string" and notice.rewardID ~= nil and notice.sig ~= nil
end

-- This officer's own signed decision, handed back by an officer who carried it: the decision
-- this officer lost when its game went down before saving (docs/fix-plan.md, P3). Without it the
-- claim reads as undecided again and can be awarded twice. Applied only where nothing here knows
-- of it yet: a decision already in the log is one this officer still has. Returns the claim
-- restored (or true for a requeue), or nil.
function OfficerClaims:restore(notice)
    if not signedNotice(notice) then return nil end
    notice.key = noticeKey(notice)
    self.log = self.log or {}
    if self.log[notice.key] then return nil end
    local restored = applyDecision(self, notice, true)
    if not restored then return nil end
    self.log[notice.key] = notice
    -- Still owed to the player unless an officer already delivered it.
    if not self.done[notice.key] then addNotice(self, notice) end
    return restored
end

-- Another decider's signed decision on a claim this officer may also decide (DEC-4): applied
-- here too, so it is not decided a second time from this side. Delivering it stays with carry().
function OfficerClaims:adopt(notice)
    if not signedNotice(notice) then return nil end
    notice.key = noticeKey(notice)
    self.log = self.log or {}
    if self.log[notice.key] then return nil end
    return applyDecision(self, notice, false)
end

-- Everything this officer should deliver to one player: its own decisions and those it carries.
function OfficerClaims:toDeliver(name)
    name = short(name)
    local out = self:untold(name)
    for _, n in pairs(self.carried) do
        if not name or n.to == name then out[#out + 1] = n end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- The player has it: no officer need carry it any longer.
function OfficerClaims:delivered(key, now)
    local had = self.notices[key] ~= nil or self.carried[key] ~= nil
    self.notices[key], self.carried[key] = nil, nil
    self.done[key] = now or self.done[key] or 0
    return had
end

-- Keys delivered since `since`, for telling other officers.
function OfficerClaims:deliveredSince(since)
    local out = {}
    for key, at in pairs(self.done) do
        if at >= (since or 0) then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

-- The decision log, newest first.
function OfficerClaims:decisions()
    local out = {}
    for _, n in pairs(self.log or {}) do out[#out + 1] = n end
    table.sort(out, function(a, b) return (a.signedAt or 0) > (b.signedAt or 0) end)
    return out
end

-- Drops decided claims the player already knows about once the grace period has passed, and
-- the awarded list for offers no longer live. isLive(rewardID) says whether an offer is still
-- on offer; without it the awarded lists are kept. opts, below, drops what has reached an ending.
function OfficerClaims:prune(now, isLive, opts)
    local told = {}
    for _, n in pairs(self.notices) do told[n.to .. "|" .. tostring(n.rewardID)] = false end
    local dropped = 0
    for id, r in pairs(self.records) do
        local pending = told[r.from .. "|" .. tostring(r.rewardID)] == false
        if r.state ~= Reward.state.submitted and not pending
            and type(r.stateAt) == "number" and now - r.stateAt > OfficerClaims.GRACE then
            self.records[id] = nil
            dropped = dropped + 1
        end
    end
    -- Delivered keys, carried decisions and the decision log keep for the grace period.
    for key, at in pairs(self.done) do
        if now - at > OfficerClaims.GRACE then self.done[key] = nil end
    end
    for _, set in ipairs({ self.carried, self.log }) do
        for key, n in pairs(set) do
            if type(n.signedAt) == "number" and now - n.signedAt > OfficerClaims.GRACE then set[key] = nil end
        end
    end
    if isLive then
        for _, t in ipairs({ self.awarded, self.allowance }) do
            for rewardID in pairs(t) do
                if not isLive(rewardID) then t[rewardID] = nil end
            end
        end
    end

    -- What has reached an ending that nobody can move any more (docs/fix-plan.md, E7). opts:
    --   ended(rewardID)  true only for an offer known here to be removed; an offer merely
    --                    missing (a list not restored after an update) has not ended
    --   inGuild(name)    true, false, or nil when that cannot be told yet
    opts = opts or {}
    for id, r in pairs(self.relays) do
        -- Held for a poster whose offer was removed (DEC-3), or who left (DEC-4).
        local gone = (opts.ended and opts.ended(r.claim.rewardID))
            or (opts.inGuild and opts.inGuild(r.issuer) == false)
        if gone then self.relays[id] = nil; dropped = dropped + 1 end
    end
    for id, r in pairs(self.records) do
        -- Undecided on an offer that has ended, past the grace period.
        if r.state == Reward.state.submitted and opts.ended and opts.ended(r.rewardID)
            and type(r.receivedAt) == "number" and now - r.receivedAt > OfficerClaims.GRACE then
            self.records[id] = nil
            dropped = dropped + 1
        end
    end
    for key, n in pairs(self.notices) do
        -- A decision for a player who has left the guild, past the grace period: they will not
        -- be back to hear it here.
        if opts.inGuild and opts.inGuild(n.to) == false
            and type(n.signedAt or n.at) == "number" and now - (n.signedAt or n.at) > OfficerClaims.GRACE then
            self.notices[key] = nil
        end
    end
    return dropped
end

function OfficerClaims:export()
    return { records = self.records, awarded = self.awarded, allowance = self.allowance,
        notices = self.notices, relays = self.relays, carried = self.carried, done = self.done, log = self.log }
end

-- Restores from saved variables, keeping only what is well formed.
function OfficerClaims:load(saved)
    self.records, self.awarded, self.allowance, self.notices, self.relays = {}, {}, {}, {}, {}
    self.carried, self.done, self.log = {}, {}, {}
    if type(saved) ~= "table" then return 0 end
    for key, at in pairs(type(saved.done) == "table" and saved.done or {}) do
        if type(key) == "string" and type(at) == "number" then self.done[key] = at end
    end
    for _, set in ipairs({ "carried", "log" }) do
        for key, n in pairs(type(saved[set]) == "table" and saved[set] or {}) do
            if type(n) == "table" and n.key == key and type(n.to) == "string" and n.rewardID ~= nil
                and type(n.sig) == "string" then
                self[set][key] = n
            end
        end
    end
    for id, r in pairs(type(saved.relays) == "table" and saved.relays or {}) do
        if type(r) == "table" and r.id == id and type(r.claim) == "table" and r.claim.rewardID ~= nil
            and type(r.from) == "string" and type(r.issuer) == "string" then
            r.saved = true          -- it came back from disk
            self.relays[id] = r
        end
    end
    local n = 0
    for id, r in pairs(type(saved.records) == "table" and saved.records or {}) do
        if type(r) == "table" and r.id == id and r.rewardID ~= nil and type(r.from) == "string"
            and type(r.at) == "number" and Reward.stateName[r.state] then
            r.saved = true          -- it came back from disk
            self.records[id] = r
            n = n + 1
        end
    end
    for _, key in ipairs({ "awarded", "allowance" }) do
        for rewardID, names in pairs(type(saved[key]) == "table" and saved[key] or {}) do
            if type(names) == "table" then
                for name, c in pairs(names) do
                    if type(name) == "string" and type(c) == "number" and c > 0 then
                        self[key][rewardID] = self[key][rewardID] or {}
                        self[key][rewardID][name] = math.floor(c)
                    end
                end
            end
        end
    end
    for _, notice in pairs(type(saved.notices) == "table" and saved.notices or {}) do
        if type(notice) == "table" and type(notice.to) == "string" and notice.rewardID ~= nil
            and (notice.kind == "state" or notice.kind == "requeue") then
            addNotice(self, notice)
        end
    end
    return n
end

if ns then ns.OfficerClaims = OfficerClaims end
return OfficerClaims
