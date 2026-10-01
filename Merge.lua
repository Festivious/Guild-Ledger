-- Content-addressed observation records that merge by union. No WoW API use.
--
-- Sightings are counted PER OBSERVER and merged with max, not summed. A blind sum would
-- make merge non-idempotent: replaying the same payload would inflate the counts, so a
-- duplicated or re-sent message would silently corrupt the corpus. Per-observer max makes
-- merge commutative, associative and idempotent, which is what lets us tolerate dropped
-- and repeated messages without any acknowledgement protocol.
--
-- It also gives the honesty property directly: one player walking past a node 100 times
-- is one observer with 100 sightings, never 100 observers.
local _, ns = ...

local Merge = {}

function Merge.newRecord(ts)
    return { firstSeen = ts, lastSeen = ts, observers = {} }
end

local function touch(record, ts)
    if ts == nil then return end
    if ts < record.firstSeen then record.firstSeen = ts end
    if ts > record.lastSeen then record.lastSeen = ts end
end

-- Adds to this observer's own total. Only ever increases it, which is what keeps the
-- per-observer value monotonic and therefore safe to merge with max.
--
-- Magnitudes (experience, durations, damage) use this with the measured amount, so one
-- record shape serves both counts and sums. Known limit, and it is a real one: max-merge
-- is exact while a SINGLE receiver accumulates, because dedupe guarantees each row is
-- added exactly once and the total only grows. Two receivers that folded DIFFERENT
-- subsets of a stream cannot be reconciled by max - A's 100 and B's 150 merge to 150 when
-- the truth is 250. Reconciling those needs the folded-row sets exchanged as well, which
-- is the same open problem as corpus redistribution.
function Merge.add(record, observerID, amount, ts)
    record.observers[observerID] = (record.observers[observerID] or 0) + (amount or 0)
    touch(record, ts)
    return record
end

-- Local sighting: the amount = 1 case.
function Merge.observe(record, observerID, ts)
    return Merge.add(record, observerID, 1, ts)
end

function Merge.copy(record)
    local observers = {}
    for id, n in pairs(record.observers) do
        observers[id] = n
    end
    return { firstSeen = record.firstSeen, lastSeen = record.lastSeen, observers = observers }
end

-- Merges src into dst and returns dst.
function Merge.merge(dst, src)
    touch(dst, src.firstSeen)
    touch(dst, src.lastSeen)
    for id, n in pairs(src.observers) do
        local current = dst.observers[id]
        if current == nil or n > current then
            dst.observers[id] = n
        end
    end
    return dst
end

-- Merges a whole key -> record set into dst and returns dst.
function Merge.mergeSet(dst, src)
    for key, record in pairs(src) do
        if dst[key] then
            Merge.merge(dst[key], record)
        else
            dst[key] = Merge.copy(record)
        end
    end
    return dst
end

function Merge.observations(record)
    local total = 0
    for _, n in pairs(record.observers) do
        total = total + n
    end
    return total
end

function Merge.observerCount(record)
    local count = 0
    for _ in pairs(record.observers) do
        count = count + 1
    end
    return count
end

if ns then ns.Merge = Merge end
return Merge
