-- Wire codec: LibSerialize -> LibDeflate -> transport-safe encoding.
--
-- The header is self-describing (version AND encoding), so a receiver never has to be told
-- out of band how to read a payload. Channel encoding costs ~2-3% overhead but emits raw
-- bytes and is NOT mail-safe; print encoding costs +33% and is safe to paste anywhere.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local LibSerialize, LibDeflate
if ns then
    LibSerialize = LibStub("LibSerialize")
    LibDeflate = LibStub("LibDeflate")
else
    LibSerialize = require("LibSerialize")
    LibDeflate = require("LibDeflate")
end

local Codec = {}

Codec.VERSION = 1
Codec.MODE_CHANNEL = "c"
Codec.MODE_PRINT = "p"

local SERIALIZE_OPTS = { errorOnUnserializableType = false }

-- Level 1, not 9. LibDeflate is pure Lua with no yield API, so CompressDeflate blocks the
-- client for however long it takes, and level 9 tripped WoW's script watchdog on a real
-- 2270-fact buffer. Measured on this data shape, level 9 costs 7x the time of level 1 at
-- 2270 facts and 15x at 20000, for a compression ratio of 1.62x instead of 1.58x.
--
-- The data is dense integers, so deflate has little to find at any level. Paying fifteen
-- times the CPU for three percent is a bad trade, and a freezing client is a worse one.
local DEFLATE_OPTS = { level = 1 }
local HEADER = "^!GBA:(%d+):(%a)!"

function Codec.encode(payload, mode)
    mode = mode or Codec.MODE_CHANNEL
    if mode ~= Codec.MODE_CHANNEL and mode ~= Codec.MODE_PRINT then
        return nil, "unknown encoding mode: " .. tostring(mode)
    end

    local serialized = LibSerialize:SerializeEx(SERIALIZE_OPTS, payload)
    local compressed = LibDeflate:CompressDeflate(serialized, DEFLATE_OPTS)

    local body
    if mode == Codec.MODE_PRINT then
        body = LibDeflate:EncodeForPrint(compressed)
    else
        body = LibDeflate:EncodeForWoWAddonChannel(compressed)
    end

    return "!GBA:" .. Codec.VERSION .. ":" .. mode .. "!" .. body
end

function Codec.decode(str)
    if type(str) ~= "string" then return nil, "payload is not a string" end

    local version, mode = str:match(HEADER)
    if not version then return nil, "missing or malformed header" end

    version = tonumber(version)
    if version > Codec.VERSION then
        return nil, "payload is schema v" .. version ..
            " but this decoder only understands v" .. Codec.VERSION
    end

    local body = str:sub(#("!GBA:" .. version .. ":" .. mode .. "!") + 1)

    local decoded
    if mode == Codec.MODE_PRINT then
        decoded = LibDeflate:DecodeForPrint(body)
    elseif mode == Codec.MODE_CHANNEL then
        decoded = LibDeflate:DecodeForWoWAddonChannel(body)
    else
        return nil, "unknown encoding mode in header: " .. tostring(mode)
    end
    if not decoded then return nil, "transport decode failed" end

    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then return nil, "decompression failed" end

    local ok, result = LibSerialize:Deserialize(decompressed)
    if not ok then return nil, "deserialization failed: " .. tostring(result) end

    return result
end

-- Crunch only: serialise and compress, and stop there. For the secure transport, where the
-- order is fixed as crunch, then lock, then encode: locked bytes look random, and random
-- bytes do not compress, so the lock must come between compressing and encoding.
function Codec.pack(payload)
    local serialized = LibSerialize:SerializeEx(SERIALIZE_OPTS, payload)
    return LibDeflate:CompressDeflate(serialized, DEFLATE_OPTS)
end

function Codec.unpack(bytes)
    if type(bytes) ~= "string" then return nil, "not a string" end
    local decompressed = LibDeflate:DecompressDeflate(bytes)
    if not decompressed then return nil, "decompression failed" end
    local ok, result = LibSerialize:Deserialize(decompressed)
    if not ok then return nil, "deserialization failed: " .. tostring(result) end
    return result
end

if ns then ns.Codec = Codec end
return Codec
