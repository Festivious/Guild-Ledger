-- Capture instrumentation. Pure, no WoW API use.
--
-- Sizing is settled by measurement rather than estimate: the spec's 15-25k facts/hour for
-- solo play is a guess until a real session says otherwise. Everything here is derived
-- from counters the capture modules already keep, so measuring costs nothing on the hot
-- path.
local _, ns = ...
if ns and ns.standDown then return end

local Metrics = {}

local SECONDS_PER_HOUR = 3600

local function perHour(count, duration)
    if not duration or duration <= 0 then return 0 end
    return count * SECONDS_PER_HOUR / duration
end

-- input: { startedAt, now, counts = {factCode -> n}, slots, guid = {...},
--          kills = {...}, sample = { bytes, facts } }
function Metrics.summarize(input)
    input = input or {}
    local duration = math.max(0, (input.now or 0) - (input.startedAt or 0))

    local counts = input.counts or {}
    local total = 0
    local byType = {}
    for code, n in pairs(counts) do
        total = total + n
        byType[#byType + 1] = { code = code, count = n, perHour = perHour(n, duration) }
    end
    table.sort(byType, function(a, b)
        if a.count == b.count then return a.code < b.code end
        return a.count > b.count
    end)

    local report = {
        duration = duration,
        totalFacts = total,
        factsPerHour = perHour(total, duration),
        byType = byType,
        slots = input.slots or 0,
        slotsPerFact = total > 0 and ((input.slots or 0) / total) or 0,
        guid = input.guid,
        kills = input.kills,
        position = input.position,
    }

    -- How often a kill had to borrow its position. A high rate means spawn evidence is
    -- being reconstructed rather than observed.
    local p = input.position
    if p then
        local attempts = (p.live or 0) + (p.fallback or 0) + (p.none or 0)
        report.positionAttempts = attempts
        report.positionFallbackRate = attempts > 0 and ((p.fallback or 0) / attempts) or 0
        report.positionMissRate = attempts > 0 and ((p.none or 0) / attempts) or 0
    end

    -- A measured sample beats a guess: encode a slice, divide, project.
    local sample = input.sample
    if sample and sample.facts and sample.facts > 0 and sample.bytes then
        report.bytesPerFact = sample.bytes / sample.facts
        report.projectedBytes = report.bytesPerFact * total
        report.projectedBytesPerHour = report.bytesPerFact * report.factsPerHour
    end

    return report
end

-- Seconds of addon-channel time a payload would need, at the ceiling Blizzard actually
-- enforces: 10 messages refilling at 1/sec, ~215 bytes of payload each.
Metrics.CHANNEL_BYTES_PER_SECOND = 215

function Metrics.channelSeconds(bytes)
    if not bytes or bytes <= 0 then return 0 end
    return bytes / Metrics.CHANNEL_BYTES_PER_SECOND
end

function Metrics.formatDuration(seconds)
    seconds = math.floor(seconds or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %02dm", hours, minutes)
    end
    return string.format("%dm %02ds", minutes, seconds % 60)
end

if ns then ns.Metrics = Metrics end
return Metrics
