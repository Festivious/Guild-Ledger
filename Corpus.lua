-- The fold: decoded facts become merge records. No WoW API use.
--
-- This is the one-way step. The guild cannot keep every contributor's raw stream, so
-- whatever is not a key dimension is gone the moment a row is folded. Everything here is
-- shaped by that: dimensions live in the key, magnitudes are kept as sums beside their
-- counts so averages stay derivable, and anything whose ordering matters is not folded at
-- all.
--
-- Rows arrive already deduplicated. That is load-bearing rather than tidy: Merge is
-- idempotent over records, but adding a row to a count is not, so a row folded twice is
-- counted twice and nothing about the result looks wrong afterwards.
local _, ns = ...
local LIB = LibStub and LibStub("LibGuildLedger-1.0", true)

local Schema, Merge, MergeKey, Coords, Provenance
if ns then
    Schema, Merge, MergeKey = LIB.Schema, ns.Merge, ns.MergeKey
    Coords, Provenance = LIB.Coords, LIB.Provenance
else
    Schema, Merge, MergeKey = require("Schema"), require("Merge"), require("MergeKey")
    Coords, Provenance = require("Coords"), require("Provenance")
end

local Corpus = {}
Corpus.__index = Corpus

-- How long an unnamed experience gain waits for a quest turn-in to claim it. Observed at
-- 0 seconds twice and 0-1 seconds across a real session; 5 is generous without being long
-- enough to reach an unrelated gain.
Corpus.QUEST_XP_WINDOW = 5

local retainedSet = {}
for _, name in ipairs(Schema.retained) do
    retainedSet[Schema.factType[name]] = true
end

function Corpus.new()
    return setmetatable({
        records = {},   -- key -> merge record, counts and measures together
        rows = {},      -- factCode -> retained rows, chain and observer intact
        rowCount = 0,
        -- sessionID -> the context the submission carried. Kept because a folded record
        -- knows WHO observed it but not WHICH session, and a retained row knows its
        -- session but not who was playing. This is what joins the two back up, and it is
        -- what a pinned episode will be addressed by.
        sessions = {},
        -- The holding pen. Every accepted row of a recent session, raw, in the order it
        -- happened. The fold cannot serve this: a kill is keyed by npc, level and group
        -- size, so folding DESTROYS the coordinate, and a map cannot plot a count.
        --
        -- Bounded by session, not by row, so one long night is never truncated halfway.
        -- Sessions age out oldest-first unless pinned; a pin is how somebody says "this
        -- one is worth keeping whole", and pinned sessions are never trimmed.
        episodes = {},
    }, Corpus)
end

-- How many unpinned sessions stay in the holding pen. Small on purpose: this is a window
-- in which to decide something is worth keeping, not an archive. The newest by ARRIVAL, not by
-- when they began: a week-old session that arrives today used to be dropped the moment it
-- landed (docs/fix-plan.md, I7, DEC-13).
Corpus.MAX_EPISODES = 10

-- How long a raw row is kept, from its arrival (DEC-15). The counts are kept for good; the raw
-- rows are the part that grows, and whole sessions keep their own copy of them.
Corpus.RAW_DAYS = 30

-- Seconds now: the caller's clock when it hands one in (the game server's), else this one.
local function clock(now)
    if type(now) == "number" then return now end
    if type(time) == "function" then return time() end
    return os.time()
end

function Corpus:isRetained(factCode)
    return retainedSet[factCode] == true
end

-- Dimensions a fact does not store but the key needs.
local function derivedDims(factCode, values)
    if values.coord == nil then return nil end
    local x, y = Coords.unpack(values.coord)
    return { spatialBucket = Coords.bucket(x, y) }
end

-- Folds one row. Returns the key it landed under, or nil and a reason.
function Corpus:fold(factCode, values, observerKey, ts)
    if self:isRetained(factCode) then return nil, "retained" end

    local dims = Schema.keyDims[factCode]
    -- A fact type with no key spec would otherwise be silently dropped here, which is the
    -- same failure that lost the death log for weeks, one layer further in.
    if not dims then return nil, "unkeyed" end

    local key = MergeKey.build(factCode, dims, values, derivedDims(factCode, values))

    local record = self.records[key]
    if not record then
        record = Merge.newRecord(ts)
        self.records[key] = record
    end
    Merge.observe(record, observerKey, ts)

    local measures = Schema.keyMeasures[factCode]
    if measures then
        for i = 1, #measures do
            local amount = values[measures[i]]
            if type(amount) == "number" then
                local mKey = MergeKey.measure(key, measures[i])
                local mRecord = self.records[mKey]
                if not mRecord then
                    mRecord = Merge.newRecord(ts)
                    self.records[mKey] = mRecord
                end
                Merge.add(mRecord, observerKey, amount, ts)
            end
        end
    end

    return key
end

-- The observer is stored on the row, not inferred later. A retained row carries its
-- session, but a session id is only a login timestamp: two contributors can share one, so
-- without this a row cannot be attributed to anybody with confidence.
function Corpus:retain(factCode, values, chain, observerKey, at)
    local list = self.rows[factCode]
    if not list then
        list = {}
        self.rows[factCode] = list
    end
    list[#list + 1] = { values = values, chain = chain, observer = observerKey, at = clock(at) }
    self.rowCount = self.rowCount + 1
end

-- Drops raw rows that arrived more than RAW_DAYS ago. Returns how many went.
function Corpus:pruneRows(now)
    local cutoff = clock(now) - Corpus.RAW_DAYS * 86400
    local dropped = 0
    for _, list in pairs(self.rows) do
        local kept = {}
        for _, row in ipairs(list) do
            if (row.at or cutoff) < cutoff then dropped = dropped + 1 else kept[#kept + 1] = row end
        end
        for i = 1, #list do list[i] = kept[i] end
    end
    self.rowCount = self.rowCount - dropped
    return dropped
end

-- Keeps one row in its session's episode. Independent of the fold: a row is both counted
-- for the corpus AND kept here, because they answer different questions. The corpus
-- answers "what drops from this mob"; the episode answers "what happened that night".
function Corpus:remember(sessionID, observerKey, code, values, chain, at)
    if sessionID == nil then return end

    local episode = self.episodes[sessionID]
    if not episode then
        episode = { sessionID = sessionID, observer = observerKey, rows = {}, pinned = false,
            arrivedAt = clock(at) }
        self.episodes[sessionID] = episode
    end
    episode.rows[#episode.rows + 1] = { code = code, values = values, chain = chain }
end

function Corpus:pin(sessionID, pinned)
    local episode = self.episodes[sessionID]
    if not episode then return false end
    episode.pinned = pinned ~= false
    return true
end

-- Newest first. sessionID is the login timestamp, so it sorts chronologically for free.
function Corpus:episodeList()
    local out = {}
    for id, episode in pairs(self.episodes) do
        out[#out + 1] = { sessionID = id, observer = episode.observer,
                          rows = #episode.rows, pinned = episode.pinned }
    end
    table.sort(out, function(a, b) return a.sessionID > b.sessionID end)
    return out
end

-- Drops the oldest unpinned episodes. Returns how many went.
function Corpus:trimEpisodes(keep)
    keep = keep or Corpus.MAX_EPISODES

    local unpinned = {}
    for id, episode in pairs(self.episodes) do
        if not episode.pinned then unpinned[#unpinned + 1] = id end
    end
    -- Newest arrival first. A session saved before arrival was recorded falls back to when it
    -- began, which is what the order used to be.
    local function arrived(id)
        local e = self.episodes[id]
        return type(e.arrivedAt) == "number" and e.arrivedAt or (tonumber(id) or 0)
    end
    table.sort(unpinned, function(a, b)
        local x, y = arrived(a), arrived(b)
        if x ~= y then return x > y end
        return tostring(a) > tostring(b)
    end)

    local dropped = 0
    for i = keep + 1, #unpinned do
        self.episodes[unpinned[i]] = nil
        dropped = dropped + 1
    end
    return dropped
end

-- Removes whole sessions: their episodes, their retained rows and their context. A folded
-- record keeps only who saw it, not which session, so an observer's share is removed from
-- the records only when none of their sessions is left. Returns sessions, rows and records
-- removed.
function Corpus:forget(sessionIDs)
    local sessions, rows, records = 0, 0, 0
    local gone = {}
    for id in pairs(sessionIDs) do
        local context = self.sessions[id]
        if context or self.episodes[id] then sessions = sessions + 1 end
        if context then gone[Provenance.observerKey(context) or ""] = true end
        self.sessions[id], self.episodes[id] = nil, nil
    end

    for _, list in pairs(self.rows) do
        local kept = {}
        for _, row in ipairs(list) do
            if row.chain and sessionIDs[row.chain.sessionID] then rows = rows + 1 else kept[#kept + 1] = row end
        end
        for i = 1, #list do list[i] = kept[i] end
    end
    self.rowCount = self.rowCount - rows

    for _, context in pairs(self.sessions) do
        local key = Provenance.observerKey(context)
        if key then gone[key] = nil end
    end
    for key, record in pairs(self.records) do
        local touched = false
        for observer in pairs(gone) do
            if record.observers[observer] then record.observers[observer], touched = nil, true end
        end
        if touched and next(record.observers) == nil then
            self.records[key] = nil
            records = records + 1
        end
    end
    return sessions, rows, records
end

-- Quest turn-ins award experience through the plain "You gain %d experience" string, which
-- is indistinguishable from any other unnamed gain at capture time, so quest XP reaches us
-- tagged `other`. A real session reported 0% of its experience from quests when 125 of 227
-- came from two turn-ins.
--
-- Capture cannot fix this: the gain arrives BEFORE the turn-in (seq 21 before 22), so at
-- the moment it is recorded there is nothing yet to attribute it to, and editing an
-- already-buffered fact would diverge from whatever a receiver already holds under that
-- seq. So it is resolved here, before the fold, while both rows are still in hand.
--
-- The claim is the same shape as the one that fixes quest abandonment: each turn-in takes
-- the nearest preceding unclaimed gain within the window, and a gain nothing claims stays
-- `other`. An unclaimed gain is not guessed at.
local function attributeQuestXP(ordered)
    local xpCode, questCode = Schema.factType.xp_gain, Schema.factType.quest_event
    local claimed = 0

    for i = 1, #ordered do
        local entry = ordered[i]
        if entry.code == questCode and entry.values.action == Schema.questAction.turnedIn then
            -- Looked for in BOTH directions, nearest in TIME.
            --
            -- The gain and the turn-in happen in the same second, and which of them the
            -- buffer sees first is not fixed: across one real session four turn-ins had
            -- their gain buffered first and a fifth had it buffered second. Searching only
            -- backwards missed that one entirely and left 875 experience in "unexplained",
            -- which is the officer view's headline number being wrong.
            --
            -- Nearest by time rather than by position, because position is buffer order
            -- and time is what actually happened.
            local best, bestGap
            for j = 1, #ordered do
                local candidate = ordered[j]
                if candidate.code == xpCode
                    and candidate.values.source == Schema.xpSource.other
                    and not candidate.claimed
                    and candidate.t ~= nil and entry.t ~= nil then

                    local gap = math.abs(entry.t - candidate.t)
                    if gap <= Corpus.QUEST_XP_WINDOW
                        and (bestGap == nil or gap < bestGap) then
                        best, bestGap = candidate, gap
                    end
                end
            end

            if best then
                best.claimed = true
                best.values.source = Schema.xpSource.questInferred
                claimed = claimed + 1
            end
        end
    end
    return claimed
end

-- Orders a payload's rows the way they happened. Sorting by t and not by seq is
-- deliberate: kills settle in an in-memory log and are flushed at submission, so their seq
-- can be far higher than facts that happened long after them. seq breaks ties, because
-- several facts routinely share a second.
local function chronological(entries)
    table.sort(entries, function(a, b)
        local at, bt = a.t or 0, b.t or 0
        if at ~= bt then return at < bt end
        return (a.seq or 0) < (b.seq or 0)
    end)
    return entries
end

-- Folds a decoded payload. `dedupe` decides which rows have already been seen; passing it
-- is not optional in practice, because the capture buffer is never drained and every
-- submission re-delivers the contributor's whole history.
--
-- Returns an audit: what arrived, what was folded, and what was dropped and why. A fact
-- type that arrives and writes no keys is exactly the kind of silent gap that has bitten
-- this project four times, so it is counted rather than assumed away.
function Corpus:ingest(payload, dedupe, now)
    local audit = {
        rows = 0, folded = 0, retained = 0,
        duplicate = 0, unsequenced = 0, unknownType = 0, unkeyed = 0,
        questXP = 0,
        byType = {},
    }

    local facts = type(payload) == "table" and payload.facts or nil
    if type(facts) ~= "table" then return audit end

    local sessions = type(payload.sessions) == "table" and payload.sessions or {}
    local observerKeys, slot = {}, {}
    for id, context in pairs(sessions) do
        local who = Provenance.observerKey(context)
        observerKeys[id] = who
        -- A session id is its login second, and two players who logged in in the same second
        -- were merged into one session (docs/fix-plan.md, I9). A session already held here for
        -- somebody else pushes this one to the next free slot, a thousandth of a second on; the
        -- same player's later rows find the same slot again. Dedupe is untouched: it already
        -- tells players apart.
        local key, k = id, 0
        while type(id) == "number" and self.sessions[key]
            and Provenance.observerKey(self.sessions[key]) ~= who and k < 50 do
            k = k + 1
            key = id + k / 1000
        end
        slot[id] = key
        self.sessions[key] = context
    end

    -- Accepted rows, unpacked once and ordered, so attribution can see across them.
    local ordered = {}

    for code, rows in pairs(facts) do
        local known = Schema.fields[code] ~= nil
        for _, row in ipairs(rows) do
            audit.rows = audit.rows + 1

            if not known then
                audit.unknownType = audit.unknownType + 1
            else
                local sessionID = Schema.chainValue(code, row, "sessionID")
                local seq = Schema.chainValue(code, row, "seq")

                local accepted, reason = true, "unsequenced"
                if dedupe then
                    accepted, reason = dedupe:offer(observerKeys[sessionID], sessionID, seq)
                end
                if reason == "unsequenced" then
                    audit.unsequenced = audit.unsequenced + 1
                end

                if not accepted then
                    audit.duplicate = audit.duplicate + 1
                else
                    local values, chain = Schema.fromWire(code, row)
                    -- Into this player's own slot, when the login second was taken.
                    if type(chain) == "table" and slot[sessionID] ~= nil and slot[sessionID] ~= sessionID then
                        chain.sessionID = slot[sessionID]
                    end
                    ordered[#ordered + 1] = {
                        code = code, values = values, chain = chain,
                        t = chain.t, seq = seq,
                        observerKey = observerKeys[sessionID],
                        -- sessionID is the login time, so absolute time is the offset on
                        -- top of it. Gives firstSeen and lastSeen a real wall clock that
                        -- is comparable between contributors.
                        ts = (sessionID and chain.t) and (sessionID + chain.t) or sessionID,
                    }
                end
            end
        end
    end

    chronological(ordered)
    audit.questXP = attributeQuestXP(ordered)

    for i = 1, #ordered do
        local entry = ordered[i]
        local name = Schema.factTypeName[entry.code] or entry.code
        audit.byType[name] = (audit.byType[name] or 0) + 1

        -- Kept raw REGARDLESS of whether it also folds. The two are independent.
        self:remember(entry.chain and entry.chain.sessionID, entry.observerKey,
            entry.code, entry.values, entry.chain, now)

        if self:isRetained(entry.code) then
            self:retain(entry.code, entry.values, entry.chain, entry.observerKey, now)
            audit.retained = audit.retained + 1
        else
            local key, why = self:fold(entry.code, entry.values, entry.observerKey, entry.ts)
            if key then
                audit.folded = audit.folded + 1
            elseif why == "unkeyed" then
                audit.unkeyed = audit.unkeyed + 1
            end
        end
    end

    audit.trimmed = self:trimEpisodes()
    audit.rowsExpired = self:pruneRows(now)
    return audit
end

function Corpus:keyCount()
    local n = 0
    for _ in pairs(self.records) do n = n + 1 end
    return n
end

-- Total sightings behind a key, across every observer.
function Corpus:observations(key)
    local record = self.records[key]
    return record and Merge.observations(record) or 0
end

-- One observer's share of a key. This is what makes a per-player report possible at all:
-- the fold drops the session, but never who was watching.
function Corpus:observationsBy(key, observerKey)
    local record = self.records[key]
    if not record or observerKey == nil then return 0 end
    return record.observers[observerKey] or 0
end

function Corpus:measureBy(key, measureName, observerKey)
    return self:observationsBy(MergeKey.measure(key, measureName), observerKey)
end

-- Everyone the corpus has heard from, from the records and the retained rows alike.
function Corpus:observers()
    local seen, out = {}, {}
    for _, record in pairs(self.records) do
        for id in pairs(record.observers) do
            if id ~= nil and not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
    end
    for _, list in pairs(self.rows) do
        for _, row in ipairs(list) do
            local id = row.observer
            if id ~= nil and not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
    end
    table.sort(out)
    return out
end

function Corpus:measure(key, measureName)
    return self:observations(MergeKey.measure(key, measureName))
end

-- What is actually held for one contributor.
--
-- Written because "what do we have on this character" was only answerable by reading the
-- fold by hand. A browser over this is the fastest way to find out where the corpus is
-- thinner than it looks - a fact type with a key spec and no keys, a session with rows but
-- no positions, a contributor whose retained rows outnumber everything folded.
function Corpus:storageFor(observerKey)
    local out = {
        keys = 0,        -- folded cells this contributor appears in
        folded = 0,      -- their own sightings across those cells
        measures = 0,    -- measure cells they appear in
        rows = 0,        -- rows kept raw
        episodes = 0,    -- sessions still held whole
        byType = {},     -- fact name -> { folded = n, rows = n }
    }
    if observerKey == nil then return out end

    for key, record in pairs(self.records) do
        local mine = record.observers[observerKey]
        if mine then
            local isMeasure = key:find("#", 1, true) ~= nil
            if isMeasure then
                out.measures = out.measures + 1
            else
                out.keys = out.keys + 1
                out.folded = out.folded + mine

                local code = tonumber(key:match("^(%d+):"))
                local name = code and (Schema.factTypeName[code] or ("type " .. code)) or "?"
                out.byType[name] = out.byType[name] or { folded = 0, rows = 0 }
                out.byType[name].folded = out.byType[name].folded + mine
            end
        end
    end

    for code, list in pairs(self.rows) do
        local name = Schema.factTypeName[code] or ("type " .. code)
        for _, row in ipairs(list) do
            if row.observer == observerKey then
                out.rows = out.rows + 1
                out.byType[name] = out.byType[name] or { folded = 0, rows = 0 }
                out.byType[name].rows = out.byType[name].rows + 1
            end
        end
    end

    for _, episode in pairs(self.episodes) do
        if episode.observer == observerKey then out.episodes = out.episodes + 1 end
    end

    return out
end

-- One contributor's held sessions, newest first. sessionID is the login timestamp, so it
-- sorts chronologically for free.
function Corpus:episodesFor(observerKey)
    local out = {}
    for id, episode in pairs(self.episodes) do
        if observerKey == nil or episode.observer == observerKey then
            -- Counted here rather than in the UI so the list is useful to anything that
            -- reads it, and so a session with rows but nothing plottable is visible.
            local positions, events = 0, 0
            for _, row in ipairs(episode.rows) do
                if row.code == Schema.factType.position then positions = positions + 1 end
                if row.values and row.values.coord then events = events + 1 end
            end

            out[#out + 1] = {
                sessionID = id,
                observer = episode.observer,
                rows = #episode.rows,
                positions = positions,
                located = events,
                pinned = episode.pinned,
                context = self.sessions[id],
            }
        end
    end
    table.sort(out, function(a, b) return a.sessionID > b.sessionID end)
    return out
end

-- Dev only (tests): no shipped path merges one corpus into another.

-- Restores from SavedVariables.
--
-- This MUST be persisted alongside the dedupe marks, and the two must not be allowed to
-- disagree. Marks that survive a logout while the corpus does not would leave a receiver
-- that rejects every re-sent row as already seen and has nothing to show for any of them -
-- strictly worse than keeping neither.
--
-- A plain table, not the binary blob with a pointer map that Questie uses and that this
-- will eventually need. Correct first, compact later, and measured before either.
function Corpus:load(records, rows, sessions, episodes)
    self.records, self.rows, self.rowCount, self.sessions = {}, {}, 0, {}
    self.episodes = {}

    if type(episodes) == "table" then
        for id, episode in pairs(episodes) do
            if type(episode) == "table" and type(episode.rows) == "table" then
                self.episodes[id] = {
                    sessionID = id, observer = episode.observer,
                    rows = episode.rows, pinned = episode.pinned == true,
                    arrivedAt = type(episode.arrivedAt) == "number" and episode.arrivedAt or nil,
                }
            end
        end
    end

    if type(sessions) == "table" then
        for id, context in pairs(sessions) do
            if type(context) == "table" then self.sessions[id] = context end
        end
    end

    if type(records) == "table" then
        for key, record in pairs(records) do
            if type(key) == "string" and type(record) == "table"
                and type(record.firstSeen) == "number" and type(record.lastSeen) == "number"
                and type(record.observers) == "table" then
                self.records[key] = Merge.copy(record)
            end
        end
    end

    if type(rows) == "table" then
        for code, list in pairs(rows) do
            if type(code) == "number" and type(list) == "table" then
                for _, row in ipairs(list) do
                    if type(row) == "table" and type(row.values) == "table" then
                        -- A row saved before arrival was recorded starts its 30 days now,
                        -- rather than all going at once on the update.
                        self:retain(code, row.values, row.chain, row.observer,
                            type(row.at) == "number" and row.at or nil)
                    end
                end
            end
        end
    end

    return self:keyCount(), self.rowCount
end

if ns then ns.Corpus = Corpus end
return Corpus
