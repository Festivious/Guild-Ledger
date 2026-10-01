-- In-memory fact buffer. Pure, no WoW API use.
--
-- Facts are stored as positional arrays (the wire format) plus the episode chain they
-- happened in, so nothing has to be re-derived at submission time.
--
-- Every fact also gets a per-session sequence number, which is what lets the receiver
-- recognise a row it has already folded. The counter is deliberately NOT part of the
-- entry list: it has to stay monotonic for the whole life of a session even when the
-- entries are drained or wiped, because a receiver that has already seen seq 1..400 will
-- silently discard a second seq 1..400 as duplicates. Restarting the count after a wipe
-- would therefore throw away everything captured afterwards, and look like nothing was
-- captured at all.
local _, ns = ...
if ns and ns.standDown then return end

local Buffer = {}
Buffer.__index = Buffer

function Buffer.new()
    return setmetatable({ entries = {}, counts = {}, seqBySession = {} }, Buffer)
end

-- Next sequence number for a session. Facts buffered without a session cannot be
-- deduplicated by the receiver, so they get no number rather than a misleading one.
function Buffer:nextSeq(sessionID)
    if sessionID == nil then return nil end
    local seq = (self.seqBySession[sessionID] or 0) + 1
    self.seqBySession[sessionID] = seq
    return seq
end

function Buffer:add(factCode, values, episode, ts)
    if type(factCode) ~= "number" or type(values) ~= "table" then return nil end

    episode = episode or {}
    self.entries[#self.entries + 1] = {
        code = factCode,
        values = values,
        sessionID = episode.sessionID,
        legID = episode.legID,
        encounterID = episode.encounterID,
        groupID = episode.groupID,
        ts = ts,
        -- Seconds into the session. sessionID is the login time, so this is just the
        -- offset, which keeps it a small integer on the wire.
        t = (ts and episode.sessionID) and (ts - episode.sessionID) or nil,
        -- Assigned once, here, and then stable: the same fact re-sent must carry the same
        -- number or the receiver cannot tell it is the same fact.
        seq = self:nextSeq(episode.sessionID),
    }
    self.counts[factCode] = (self.counts[factCode] or 0) + 1
    return #self.entries
end

function Buffer:count()
    return #self.entries
end

function Buffer:countByType()
    local out = {}
    for code, n in pairs(self.counts) do out[code] = n end
    return out
end

-- Rough in-memory size, for the instrumentation in M6. Counts numeric slots rather than
-- guessing at Lua's allocator.
function Buffer:slotCount()
    local slots = 0
    for _, entry in ipairs(self.entries) do
        slots = slots + #entry.values
    end
    return slots
end

-- Restores persisted entries, rebuilding the per-type counts rather than trusting a
-- saved copy of them: the entries are the source of truth.
--
-- The sequence allocator is the exception. It has to survive a drain or a wipe, which
-- remove the very entries it would otherwise be rebuilt from, so the saved counters are
-- authoritative and the entries can only push them higher. Entries saved before
-- sequencing existed are backfilled, so upgrading does not leave a buffer full of rows
-- the receiver has no way to recognise.
function Buffer:load(entries, seqBySession)
    self.entries, self.counts, self.seqBySession = {}, {}, {}

    if type(seqBySession) == "table" then
        for id, seq in pairs(seqBySession) do
            if type(seq) == "number" then self.seqBySession[id] = seq end
        end
    end

    if type(entries) ~= "table" then return 0 end

    -- Highest number already in use, established before anything is backfilled so a
    -- backfilled entry can never be handed a number an earlier one already has.
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.seq) == "number"
            and entry.sessionID ~= nil then
            local known = self.seqBySession[entry.sessionID]
            if known == nil or entry.seq > known then
                self.seqBySession[entry.sessionID] = entry.seq
            end
        end
    end

    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.code) == "number"
            and type(entry.values) == "table" then
            if entry.seq == nil then entry.seq = self:nextSeq(entry.sessionID) end
            self.entries[#self.entries + 1] = entry
            self.counts[entry.code] = (self.counts[entry.code] or 0) + 1
        end
    end
    return #self.entries
end

-- Note that neither drain nor wipe touches seqBySession. Emptying the buffer must not
-- restart the count, or everything captured afterwards collides with numbers the
-- receiver has already folded and is discarded as duplicate.
function Buffer:drain()
    local entries = self.entries
    self.entries, self.counts = {}, {}
    return entries
end

function Buffer:wipe()
    self.entries, self.counts = {}, {}
end

-- Puts an unlocked session's rows back, from the archive (Archive.lua). They keep their own
-- numbers; the allocator only ever moves up, so a number already used is never handed out again.
function Buffer:restoreRows(rows)
    for _, entry in ipairs(type(rows) == "table" and rows or {}) do
        if type(entry) == "table" and type(entry.code) == "number" and type(entry.values) == "table" then
            self.entries[#self.entries + 1] = entry
            self.counts[entry.code] = (self.counts[entry.code] or 0) + 1
            local sid, seq = entry.sessionID, entry.seq
            if sid ~= nil and type(seq) == "number" and (self.seqBySession[sid] or 0) < seq then
                self.seqBySession[sid] = seq
            end
        end
    end
end

-- Takes one session's rows out, for the archive (Archive.lua). The numbering is kept, like
-- drain and wipe keep it. Returns how many rows went.
function Buffer:removeSession(sessionID)
    local kept, counts, removed = {}, {}, 0
    for _, entry in ipairs(self.entries) do
        if entry.sessionID == sessionID then
            removed = removed + 1
        else
            kept[#kept + 1] = entry
            counts[entry.code] = (counts[entry.code] or 0) + 1
        end
    end
    self.entries, self.counts = kept, counts
    return removed
end

if ns then ns.Buffer = Buffer end
return Buffer
