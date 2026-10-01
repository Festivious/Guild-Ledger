-- Chunking and reassembly for addon-channel transfers. Pure, no WoW API use.
--
-- A fixed-width header is parsed by position rather than split on a delimiter, because
-- EncodeForWoWAddonChannel is CreateCodec("\000", "\001", "") - it guarantees only that
-- \000 is absent. Pipes, newlines and percent signs all survive encoding, so any
-- delimiter-based framing would corrupt on some payloads and look fine on most.
--
-- No checksum is carried. A chunk lost in transit produces a short or scrambled payload,
-- and the codec already rejects that cleanly at decompression or deserialization, so a
-- checksum would only duplicate a guard that exists. What framing must add is detection
-- of MISSING chunks, which sequence and total numbers give directly.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Framing = {}

-- Blizzard caps an addon message at 255 bytes. The prefix is a separate argument and does
-- not count against it.
Framing.MAX_MESSAGE = 255

-- "1" version | 4 transfer id | 3 sequence | 3 total
Framing.HEADER_SIZE = 11
Framing.MAX_BODY = Framing.MAX_MESSAGE - Framing.HEADER_SIZE
Framing.MAX_PARTS = 999
Framing.VERSION = "1"

local ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local ID_LENGTH = 4

-- Transfer ids only need to avoid colliding with another in-flight transfer from the same
-- sender, so four characters is ample.
function Framing.newTransferID(random)
    random = random or math.random
    local out = {}
    for i = 1, ID_LENGTH do
        local index = random(#ID_ALPHABET)
        out[i] = ID_ALPHABET:sub(index, index)
    end
    return table.concat(out)
end

function Framing.partCount(payload)
    if type(payload) ~= "string" or #payload == 0 then return 0 end
    return math.ceil(#payload / Framing.MAX_BODY)
end

-- Returns an array of wire-ready messages, or nil plus a reason.
function Framing.split(payload, transferID)
    if type(payload) ~= "string" or #payload == 0 then
        return nil, "empty payload"
    end
    if type(transferID) ~= "string" or #transferID ~= ID_LENGTH then
        return nil, "transfer id must be " .. ID_LENGTH .. " characters"
    end

    local total = Framing.partCount(payload)
    if total > Framing.MAX_PARTS then
        return nil, "payload needs " .. total .. " parts, limit is " .. Framing.MAX_PARTS
    end

    local parts = {}
    for seq = 1, total do
        local from = (seq - 1) * Framing.MAX_BODY + 1
        local body = payload:sub(from, from + Framing.MAX_BODY - 1)
        parts[seq] = string.format("%s%s%03d%03d%s",
            Framing.VERSION, transferID, seq, total, body)
    end
    return parts
end

function Framing.parse(message)
    if type(message) ~= "string" or #message < Framing.HEADER_SIZE then
        return nil, "message shorter than the header"
    end

    local version = message:sub(1, 1)
    if version ~= Framing.VERSION then
        return nil, "unknown framing version: " .. version
    end

    local transferID = message:sub(2, 5)
    local seq = tonumber(message:sub(6, 8))
    local total = tonumber(message:sub(9, 11))
    if not seq or not total then return nil, "malformed sequence header" end
    if seq < 1 or total < 1 or seq > total then return nil, "sequence out of range" end

    return {
        transferID = transferID,
        seq = seq,
        total = total,
        body = message:sub(Framing.HEADER_SIZE + 1),
    }
end

-- Reassembler

local Reassembler = {}
Reassembler.__index = Reassembler
Framing.Reassembler = Reassembler

local DEFAULT_TTL = 120

function Reassembler.new(opts)
    opts = opts or {}
    return setmetatable({
        ttl = opts.ttl or DEFAULT_TTL,
        transfers = {},
    }, Reassembler)
end

-- `sender` keeps concurrent transfers from different players apart; a sender may also
-- have more than one transfer in flight, so the key includes the transfer id.
function Reassembler:accept(sender, message, now)
    local part, err = Framing.parse(message)
    if not part then return nil, err end

    local key = tostring(sender) .. "\0" .. part.transferID
    local transfer = self.transfers[key]
    if not transfer then
        transfer = { total = part.total, received = 0, parts = {}, updatedAt = now }
        self.transfers[key] = transfer
    end

    if part.total ~= transfer.total then
        self.transfers[key] = nil
        return nil, "part count changed mid-transfer"
    end

    transfer.updatedAt = now

    -- Duplicates are ignored rather than counted, so a resent chunk cannot complete a
    -- transfer that is still missing a different one.
    if transfer.parts[part.seq] then return nil end

    transfer.parts[part.seq] = part.body
    transfer.received = transfer.received + 1

    if transfer.received < transfer.total then return nil end

    local ordered = {}
    for seq = 1, transfer.total do
        ordered[seq] = transfer.parts[seq]
    end
    self.transfers[key] = nil
    return table.concat(ordered)
end

-- Incomplete transfers are discarded rather than kept forever. Because merging is
-- idempotent, the sender can simply send the whole thing again at no semantic cost.
function Reassembler:prune(now)
    local dropped = 0
    for key, transfer in pairs(self.transfers) do
        if now - transfer.updatedAt > self.ttl then
            self.transfers[key] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end

function Reassembler:pendingCount()
    local n = 0
    for _ in pairs(self.transfers) do n = n + 1 end
    return n
end

-- Which parts a stalled transfer is still waiting on, for diagnostics.
function Reassembler:missingParts(sender, transferID)
    local transfer = self.transfers[tostring(sender) .. "\0" .. transferID]
    if not transfer then return nil end
    local missing = {}
    for seq = 1, transfer.total do
        if not transfer.parts[seq] then missing[#missing + 1] = seq end
    end
    return missing
end

if ns then ns.Framing = Framing end
return Framing
