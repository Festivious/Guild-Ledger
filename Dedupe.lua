-- Receive-side duplicate suppression. No WoW API use.
--
-- Merging is idempotent; the fold from facts INTO merge records is not. The receiver
-- increments a counter for every row it is handed, so a row handed to it twice is counted
-- twice. Nothing upstream prevents that: the capture buffer is never drained, so every
-- /gba send re-sends the whole history and overlapping delivery is the normal case rather
-- than a rare accident. Without this the corpus is multiplied by however many times the
-- contributor pressed send, and the result looks entirely plausible.
--
-- Each (observer, session) pair is an independent stream of sequence numbers. A
-- high-water mark on its own would be enough if batches always arrived in order, but
-- nothing guarantees that, and a mark advanced by a later batch would reject an earlier
-- one for good. Losing observations is worse than counting them twice, so the mark is
-- paired with the set of numbers seen beyond it, and contiguous runs collapse into the
-- mark. It is the receiver half of a sliding window; when delivery is in order the set is
-- always empty, and the cost is one integer per session.
--
-- If a batch is genuinely lost, everything after it stays in that set until a re-send
-- fills the gap. At the measured ~940 facts/hour that is bounded in practice, so it is
-- reported by pending() rather than capped on a guess.
local _, ns = ...

local Dedupe = {}
Dedupe.__index = Dedupe

-- A session whose context carries no name cannot be attributed to anybody. Its rows are
-- still deduplicated against each other, because the alternative is inflating the corpus
-- with re-sends, but they share a stream with any other nameless session that logged in
-- the same second. Those are already unattributable, so nothing further is lost.
local UNKNOWN_OBSERVER = "?"

function Dedupe.new()
    return setmetatable({ streams = {} }, Dedupe)
end

-- "/" cannot occur in a character name or a realm name, so it can never be mistaken for
-- part of either.
function Dedupe.streamKey(observerKey, sessionID)
    if sessionID == nil then return nil end
    return tostring(observerKey or UNKNOWN_OBSERVER) .. "/" .. tostring(sessionID)
end

-- Returns whether this row should be folded, and a word saying why:
--   true,  "new"          first sighting
--   false, "duplicate"    already folded, drop it
--   true,  "unsequenced"  no stream to place it in; folded, but it can arrive again
--
-- Calling this is what consumes the number, so it must be called exactly once per row.
function Dedupe:offer(observerKey, sessionID, seq)
    local streamKey = Dedupe.streamKey(observerKey, sessionID)
    if streamKey == nil or type(seq) ~= "number" then
        return true, "unsequenced"
    end

    local stream = self.streams[streamKey]
    if not stream then
        stream = { mark = 0, ahead = {} }
        self.streams[streamKey] = stream
    end

    if seq <= stream.mark then return false, "duplicate" end
    if stream.ahead[seq] then return false, "duplicate" end

    stream.ahead[seq] = true

    -- Absorb whatever is now contiguous, so an out-of-order run costs memory only until
    -- the gap it is waiting on is filled.
    local mark = stream.mark
    while stream.ahead[mark + 1] do
        mark = mark + 1
        stream.ahead[mark] = nil
    end
    stream.mark = mark

    return true, "new"
end

-- Highest contiguous sequence number folded for a stream.
function Dedupe:highWater(observerKey, sessionID)
    local streamKey = Dedupe.streamKey(observerKey, sessionID)
    local stream = streamKey and self.streams[streamKey]
    return stream and stream.mark or 0
end

function Dedupe:streamCount()
    local count = 0
    for _ in pairs(self.streams) do count = count + 1 end
    return count
end

-- Rows accepted but still waiting on an earlier gap. Zero in ordinary operation; a number
-- that keeps climbing means batches are being lost rather than merely reordered.
function Dedupe:pending()
    local total = 0
    for _, stream in pairs(self.streams) do
        for _ in pairs(stream.ahead) do total = total + 1 end
    end
    return total
end

-- Restores from SavedVariables. This state MUST survive logout: a receiver that forgets
-- its marks re-folds every row the next contributor re-sends, which is the exact failure
-- the module exists to prevent.
function Dedupe:load(streams)
    self.streams = {}
    if type(streams) ~= "table" then return 0 end

    for key, stream in pairs(streams) do
        if type(key) == "string" and type(stream) == "table"
            and type(stream.mark) == "number" then
            local ahead = {}
            if type(stream.ahead) == "table" then
                for seq in pairs(stream.ahead) do
                    if type(seq) == "number" then ahead[seq] = true end
                end
            end
            self.streams[key] = { mark = stream.mark, ahead = ahead }
        end
    end
    return self:streamCount()
end

if ns then ns.Dedupe = Dedupe end
return Dedupe
