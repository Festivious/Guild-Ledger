-- Turns the capture buffer into payloads and hands them to a transport.
--
-- Submissions are batched. LibDeflate blocks the client for the whole of a compression,
-- and the cost grows superlinearly with input size, so a buffer left to accumulate for
-- days would eventually freeze the game the moment it was submitted. Batching bounds the
-- work per call regardless of how much has been recorded.
--
-- Multiple batches are safe because merging is idempotent: a batch that fails, arrives
-- twice, or arrives out of order costs only the bytes to carry it.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema, Provenance = GBA.Schema, GBA.Provenance
local buffer = ns.buffer

local Submit = {}
ns.Submit = Submit

-- Measured: at this size one compression is a brief hitch rather than a freeze.
Submit.MAX_FACTS_PER_BATCH = 1500

-- Sweeps anything still held in memory into the buffer: kills waiting to settle, the
-- fight in progress, and the current zone leg.
function Submit.prepare()
    if ns.flushKills then ns.flushKills(true) end
    if ns.closeOpenEpisodes then ns.closeOpenEpisodes() end
    -- The session summary travels with the payload, so it has to be brought up to date
    -- here too and not only at logout.
    if ns.updateSessionLevel then ns.updateSessionLevel() end
    return #buffer.entries
end

-- Facts and their session context, optionally narrowed to ONE session.
--
-- Used when a reward asks for a single session: the player gathers exactly that and
-- nothing else, so the rest never leaves the machine. Sending everything and asking the
-- receiver to forget would not be a boundary at all.
-- `allowed`, when given, is a set of fact codes: only those are gathered. What is not
-- gathered is never sent and so can never be read (backbone invariant 2, "filter at gather,
-- never send-everything-and-trust-the-receiver").
function Submit.gather(sessionID, allowed)
    local facts, sessions = {}, {}

    for _, entry in ipairs(buffer.entries) do
        if (sessionID == nil or entry.sessionID == sessionID) and (not allowed or allowed[entry.code]) then
            facts[entry.code] = facts[entry.code] or {}
            table.insert(facts[entry.code], Schema.withChain(entry.code, entry.values, entry))
            if entry.sessionID and ns.sessions[entry.sessionID] then
                sessions[entry.sessionID] = ns.sessions[entry.sessionID]
            end
        end
    end

    return facts, sessions
end

function Submit.batchCount()
    return math.ceil(#buffer.entries / Submit.MAX_FACTS_PER_BATCH)
end

-- Builds one batch, 1-indexed. Returns payload, factCount.
function Submit.buildPayload(batchIndex)
    batchIndex = batchIndex or 1

    local entries = buffer.entries
    if #entries == 0 then return nil, "nothing captured yet" end

    local first = (batchIndex - 1) * Submit.MAX_FACTS_PER_BATCH + 1
    local last = math.min(first + Submit.MAX_FACTS_PER_BATCH - 1, #entries)
    if first > #entries then return nil, "no such batch" end

    -- Each row carries its episode chain. Without it the receiver gets a flat pile of
    -- facts with no way to tell which run, zone, fight or group they came from.
    local facts = {}
    for i = first, last do
        local entry = entries[i]
        facts[entry.code] = facts[entry.code] or {}
        table.insert(facts[entry.code], Schema.withChain(entry.code, entry.values, entry))
    end

    -- Only the sessions this batch actually references, so a batch stays self-contained.
    local sessions = {}
    for i = first, last do
        local id = entries[i].sessionID
        if id and ns.sessions[id] then sessions[id] = ns.sessions[id] end
    end

    return {
        -- One prefix carries rewards as well as observations now, so a payload has to say
        -- what it is rather than the receiver assuming.
        kind = Schema.messageKind.facts,
        -- The envelope describes the client that SENT this. Who OBSERVED each fact comes
        -- from its chain's sessionID, resolved through the sessions table: a buffer can
        -- hold several characters' work, and reading the observer from whoever happens to
        -- be logged in at send time attributes it to the wrong person entirely.
        envelope = Provenance.build(
            Provenance.readEnvironment(GBA.version, Schema.VERSION),
            GBA.spokes:versions()),
        sessions = sessions,
        facts = facts,
    }, last - first + 1
end
