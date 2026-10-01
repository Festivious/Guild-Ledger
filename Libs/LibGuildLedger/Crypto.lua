-- Crypto for GuildLedger. Pure Lua, no WoW API. Ported from the ChannelLab test addon, where
-- every piece ran in game on 2026-09-23 (see docs/superpowers/specs/2026-09-23-secure-transport-design.md).
--
-- One primitive, SHA-256, and everything built from it:
--
--   hmac(key, msg)        HMAC-SHA256, for deriving names, passwords and keys
--   seal(key, plain)      encrypt-then-MAC: SHA-256 in counter mode as the keystream,
--                         HMAC over nonce and ciphertext as the tag
--   open(key, wire)       the reverse; refuses anything whose tag does not verify
--
-- Bit operations come from the `bit` library when the client has one, and from plain
-- arithmetic when it does not. Whether WoW Classic Era has `bit` is gate V1 of the
-- backbone plan, so this file reports which path it took instead of assuming.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto = {}

local MOD = 4294967296 -- 2^32
local floor = math.floor
local char, byte, format = string.char, string.byte, string.format

-- Bit operations ---------------------------------------------------------------------

-- Every result is normalised to an unsigned 32-bit number, because LuaJIT's bit library
-- returns signed values and WoW's returns unsigned ones.
local band, bor, bxor, bnot, rshift, lshift

local function useBitLibrary(b)
    band = function(a, c) return b.band(a, c) % MOD end
    bor = function(a, c) return b.bor(a, c) % MOD end
    bxor = function(a, c) return b.bxor(a, c) % MOD end
    bnot = function(a) return b.bnot(a) % MOD end
    rshift = function(a, n) return b.rshift(a, n) % MOD end
    lshift = function(a, n) return b.lshift(a, n) % MOD end
    Crypto.bitSource = "bit library"
end

-- Arithmetic fallback. AND and XOR go four bits at a time through 16x16 tables.
local function useArithmetic()
    local andT, xorT = {}, {}
    for x = 0, 15 do
        andT[x], xorT[x] = {}, {}
        for y = 0, 15 do
            local a, o = 0, 0
            for bitIndex = 0, 3 do
                local p = 2 ^ bitIndex
                local xb, yb = floor(x / p) % 2, floor(y / p) % 2
                if xb == 1 and yb == 1 then a = a + p end
                if xb ~= yb then o = o + p end
            end
            andT[x][y], xorT[x][y] = a, o
        end
    end

    local function nibbles(t, a, c)
        local result, place = 0, 1
        for _ = 1, 8 do
            result = result + t[a % 16][c % 16] * place
            a, c, place = floor(a / 16), floor(c / 16), place * 16
        end
        return result
    end

    band = function(a, c) return nibbles(andT, a % MOD, c % MOD) end
    bxor = function(a, c) return nibbles(xorT, a % MOD, c % MOD) end
    bor = function(a, c)
        a, c = a % MOD, c % MOD
        return a + c - nibbles(andT, a, c)
    end
    bnot = function(a) return MOD - 1 - (a % MOD) end
    rshift = function(a, n) return floor((a % MOD) / 2 ^ n) end
    lshift = function(a, n) return ((a % MOD) * 2 ^ n) % MOD end
    Crypto.bitSource = "arithmetic"
end

-- Picks the bit path. Tests call this to force each path in turn.
function Crypto.selectBits(forceArithmetic)
    local b = rawget(_G, "bit")
    if not forceArithmetic and type(b) == "table" and b.bxor then
        useBitLibrary(b)
    else
        useArithmetic()
    end
    return Crypto.bitSource
end

Crypto.selectBits()

-- The bit operations currently selected, for other modules (SHA-512) that need them.
function Crypto.bitops()
    return { band = band, bor = bor, bxor = bxor, bnot = bnot, rshift = rshift, lshift = lshift }
end

local function rrotate(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

-- SHA-256 ----------------------------------------------------------------------------

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function toBytes32(n)
    return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

-- One 64-byte block of `msg` at `chunk`, folded into the state h (h[1]..h[8]).
local w = {}
local function compress(h, msg, chunk)
        for i = 0, 15 do
            local b1, b2, b3, b4 = byte(msg, chunk + i * 4, chunk + i * 4 + 3)
            w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(bxor(rrotate(x, 7), rrotate(x, 18)), rshift(x, 3))
            local s1 = bxor(bxor(rrotate(y, 17), rrotate(y, 19)), rshift(y, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
        end

        local h0, h1, h2, h3, h4, h5, h6, h7 = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        local a, b, c, d, e, f, g, hh = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (hh + S1 + ch + K[i + 1] + w[i]) % MOD
            local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = (S0 + maj) % MOD
            hh, g, f, e = g, f, e, (d + t1) % MOD
            d, c, b, a = c, b, a, (t1 + t2) % MOD
        end

        h[1], h[2], h[3], h[4] = (h0 + a) % MOD, (h1 + b) % MOD, (h2 + c) % MOD, (h3 + d) % MOD
        h[5], h[6], h[7], h[8] = (h4 + e) % MOD, (h5 + f) % MOD, (h6 + g) % MOD, (h7 + hh) % MOD
end

local function initial()
    return { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
end

-- The padding SHA-256 appends to a message of `length` bytes.
local function padding(length)
    local bitLength = length * 8
    return "\128" .. string.rep("\0", (55 - length) % 64)
        .. toBytes32(floor(bitLength / MOD)) .. toBytes32(bitLength % MOD)
end

local function digestOf(h)
    return toBytes32(h[1]) .. toBytes32(h[2]) .. toBytes32(h[3]) .. toBytes32(h[4])
        .. toBytes32(h[5]) .. toBytes32(h[6]) .. toBytes32(h[7]) .. toBytes32(h[8])
end

-- Returns the 32-byte binary digest.
function Crypto.sha256(msg)
    local h = initial()
    msg = msg .. padding(#msg)
    for chunk = 1, #msg, 64 do compress(h, msg, chunk) end
    return digestOf(h)
end

-- SHA-256 fed a piece at a time: hasher:update(piece) any number of times, then hasher:final().
-- The same digest as Crypto.sha256 of all the pieces joined. For work too long for one frame.
function Crypto.newSha256()
    local h, buffer, length = initial(), "", 0
    local hasher = {}
    function hasher:update(piece)
        length = length + #piece
        buffer = buffer .. piece
        local whole = #buffer - #buffer % 64
        for chunk = 1, whole, 64 do compress(h, buffer, chunk) end
        buffer = buffer:sub(whole + 1)
    end
    function hasher:final()
        local tail = buffer .. padding(length)
        for chunk = 1, #tail, 64 do compress(h, tail, chunk) end
        return digestOf(h)
    end
    return hasher
end

-- Helpers ----------------------------------------------------------------------------

function Crypto.toHex(s)
    return (s:gsub(".", function(c) return format("%02x", byte(c)) end))
end

function Crypto.fromHex(h)
    if type(h) ~= "string" or #h % 2 ~= 0 or h:find("[^%x]") then return nil end
    return (h:gsub("%x%x", function(pair) return char(tonumber(pair, 16)) end))
end

-- XOR of two equal-length strings, a byte at a time.
local function xorStrings(a, b)
    local out = {}
    for i = 1, #a do
        out[i] = char(bxor(byte(a, i), byte(b, i)) % 256)
    end
    return table.concat(out)
end

-- Compares without stopping at the first difference.
local function sameBytes(a, b)
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bor(diff, bxor(byte(a, i), byte(b, i)))
    end
    return diff == 0
end

-- HMAC-SHA256 ------------------------------------------------------------------------

function Crypto.hmac(key, msg)
    if #key > 64 then key = Crypto.sha256(key) end
    key = key .. string.rep("\0", 64 - #key)
    local inner = xorStrings(key, string.rep("\54", 64))
    local outer = xorStrings(key, string.rep("\92", 64))
    return Crypto.sha256(outer .. Crypto.sha256(inner .. msg))
end

-- Sealing ----------------------------------------------------------------------------

Crypto.NONCE_BYTES = 8
Crypto.TAG_BYTES = 8

-- Keystream block i is SHA-256(key .. nonce .. i). Encrypting and decrypting are the
-- same XOR, which is why a nonce must never repeat under one key.
local function keystream(key, nonce, length)
    local blocks = {}
    for i = 1, math.ceil(length / 32) do
        blocks[i] = Crypto.sha256(key .. nonce .. toBytes32(i))
    end
    return table.concat(blocks):sub(1, length)
end

-- Encrypts `plain` under `key` with the given 8-byte nonce. Returns the wire string:
--   E1:<nonce hex>:<ciphertext hex>:<tag hex>
function Crypto.seal(key, plain, nonce)
    assert(type(nonce) == "string" and #nonce == Crypto.NONCE_BYTES, "nonce must be 8 bytes")
    local cipher = xorStrings(plain, keystream(key, nonce, #plain))
    local tag = Crypto.hmac(key, "tag|" .. nonce .. cipher):sub(1, Crypto.TAG_BYTES)
    return "E1:" .. Crypto.toHex(nonce) .. ":" .. Crypto.toHex(cipher) .. ":" .. Crypto.toHex(tag)
end

-- Returns the plaintext, or nil and a reason. A tag that does not verify is refused
-- before anything is decrypted: a wrong key and a tampered message look the same, and
-- both are refusals, never a guess.
function Crypto.open(key, wire)
    if type(wire) ~= "string" then return nil, "not a string" end
    local nonceHex, cipherHex, tagHex = wire:match("^E1:(%x+):(%x*):(%x+)$")
    if not nonceHex then return nil, "not a sealed message" end

    local nonce, cipher, tag = Crypto.fromHex(nonceHex), Crypto.fromHex(cipherHex), Crypto.fromHex(tagHex)
    if not nonce or #nonce ~= Crypto.NONCE_BYTES then return nil, "bad nonce" end
    if not cipher or not tag or #tag ~= Crypto.TAG_BYTES then return nil, "bad body" end

    local expected = Crypto.hmac(key, "tag|" .. nonce .. cipher):sub(1, Crypto.TAG_BYTES)
    if not sameBytes(tag, expected) then return nil, "tag does not verify (wrong key or tampered)" end

    return xorStrings(cipher, keystream(key, nonce, #cipher))
end

-- Raw forms: nonce .. ciphertext .. tag as bytes, with no hex. Hex doubles the size at every
-- layer, which a bulk transfer cannot afford: two layers of hex is four times the data.
function Crypto.sealRaw(key, plain, nonce)
    assert(type(nonce) == "string" and #nonce == Crypto.NONCE_BYTES, "nonce must be 8 bytes")
    local cipher = xorStrings(plain, keystream(key, nonce, #plain))
    return nonce .. cipher .. Crypto.hmac(key, "tag|" .. nonce .. cipher):sub(1, Crypto.TAG_BYTES)
end

function Crypto.openRaw(key, blob)
    if type(blob) ~= "string" or #blob < Crypto.NONCE_BYTES + Crypto.TAG_BYTES then
        return nil, "too short"
    end
    local nonce = blob:sub(1, Crypto.NONCE_BYTES)
    local cipher = blob:sub(Crypto.NONCE_BYTES + 1, -Crypto.TAG_BYTES - 1)
    local tag = blob:sub(-Crypto.TAG_BYTES)
    local expected = Crypto.hmac(key, "tag|" .. nonce .. cipher):sub(1, Crypto.TAG_BYTES)
    if not sameBytes(tag, expected) then return nil, "tag does not verify (wrong key or tampered)" end
    return xorStrings(cipher, keystream(key, nonce, #cipher))
end

-- Opening in steps ---------------------------------------------------------------------------

-- Crypto.openRaw, a step at a time: job:step(n) does about n SHA-256 blocks of work and returns
-- true once finished; then job.result is the plaintext, or nil with job.err. The same answer as
-- openRaw. Seen in game (2026-09-27): a 13 KB session opened whole was stopped by the game with
-- "script ran too long", so a session is never opened whole in game (see openRawAsync).
function Crypto.openRawJob(key, blob)
    local job = {}
    if type(blob) ~= "string" or #blob < Crypto.NONCE_BYTES + Crypto.TAG_BYTES then
        job.err = "too short"
        function job:step() return true end
        return job
    end
    local nonce = blob:sub(1, Crypto.NONCE_BYTES)
    local cipher = blob:sub(Crypto.NONCE_BYTES + 1, -Crypto.TAG_BYTES - 1)
    local tag = blob:sub(-Crypto.TAG_BYTES)

    -- The HMAC, as Crypto.hmac computes it; its inner hash is the long one, fed in pieces.
    local hkey = #key > 64 and Crypto.sha256(key) or key
    hkey = hkey .. string.rep("\0", 64 - #hkey)
    local inner = Crypto.newSha256()
    inner:update(xorStrings(hkey, string.rep("\54", 64)))
    local message = "tag|" .. nonce .. cipher
    local fed, block, stage = 0, 0, "mac"
    local plain = {}
    local blocks = math.ceil(#cipher / 32)

    function job:step(n)
        local budget = n or 32
        while budget > 0 do
            if stage == "mac" then
                if fed < #message then
                    inner:update(message:sub(fed + 1, fed + 64))
                    fed = fed + 64
                else
                    local expected = Crypto.sha256(xorStrings(hkey, string.rep("\92", 64)) .. inner:final())
                    if not sameBytes(tag, expected:sub(1, Crypto.TAG_BYTES)) then
                        job.err = "tag does not verify (wrong key or tampered)"
                        return true
                    end
                    stage = "decrypt"
                end
            else
                if block >= blocks then
                    job.result = table.concat(plain)
                    return true
                end
                block = block + 1
                local piece = cipher:sub((block - 1) * 32 + 1, block * 32)
                local stream = Crypto.sha256(key .. nonce .. toBytes32(block))
                plain[block] = xorStrings(piece, stream:sub(1, #piece))
            end
            budget = budget - 1
        end
        return false
    end
    return job
end

-- Crypto.sealRaw, a step at a time, the mirror of openRawJob: the same bytes as sealRaw, made a
-- few SHA-256 blocks at a time, because sealing a whole session at once is as heavy as opening
-- one. job:step(n) returns true once finished; then job.result is the sealed blob.
function Crypto.sealRawJob(key, plain, nonce)
    assert(type(nonce) == "string" and #nonce == Crypto.NONCE_BYTES, "nonce must be 8 bytes")
    local job = {}
    local blocks = math.ceil(#plain / 32)
    local cipher, block, stage = {}, 0, "encrypt"
    local hkey = #key > 64 and Crypto.sha256(key) or key
    hkey = hkey .. string.rep("\0", 64 - #hkey)
    local inner, message, fed

    function job:step(n)
        local budget = n or 32
        while budget > 0 do
            if stage == "encrypt" then
                if block >= blocks then
                    message = "tag|" .. nonce .. table.concat(cipher)
                    inner = Crypto.newSha256()
                    inner:update(xorStrings(hkey, string.rep("\54", 64)))
                    fed, stage = 0, "mac"
                else
                    block = block + 1
                    local piece = plain:sub((block - 1) * 32 + 1, block * 32)
                    local stream = Crypto.sha256(key .. nonce .. toBytes32(block))
                    cipher[block] = xorStrings(piece, stream:sub(1, #piece))
                end
            else
                if fed < #message then
                    inner:update(message:sub(fed + 1, fed + 64))
                    fed = fed + 64
                else
                    local tag = Crypto.sha256(xorStrings(hkey, string.rep("\92", 64)) .. inner:final())
                    job.result = nonce .. table.concat(cipher) .. tag:sub(1, Crypto.TAG_BYTES)
                    return true
                end
            end
            budget = budget - 1
        end
        return false
    end
    return job
end

-- In game: seals over as many frames as it takes. done(blob).
function Crypto.sealRawAsync(key, plain, nonce, done, blocksPerFrame)
    local job = Crypto.sealRawJob(key, plain, nonce)
    local function tick()
        if job:step(blocksPerFrame or 24) then
            done(job.result)
        else
            C_Timer.After(0, tick)
        end
    end
    C_Timer.After(0, tick)
end

-- In game: opens over as many frames as it takes, a few blocks per frame, starting on the next
-- frame so it never shares one with whatever finished just before it. done(plain) or done(nil, err).
function Crypto.openRawAsync(key, blob, done, blocksPerFrame)
    local job = Crypto.openRawJob(key, blob)
    local function tick()
        if job:step(blocksPerFrame or 24) then
            done(job.result, job.err)
        else
            C_Timer.After(0, tick)
        end
    end
    C_Timer.After(0, tick)
end

-- Addon messages cannot carry a zero byte. \1 is the escape: \1 -> \1\1, \0 -> \1\2.
-- Random bytes grow by about 1 in 128 on average.
function Crypto.escape(s)
    return (s:gsub("[%z\1]", function(c) return c == "\1" and "\1\1" or "\1\2" end))
end

function Crypto.unescape(s)
    return (s:gsub("\1([\1\2])", function(c) return c == "\1" and "\1" or "\0" end))
end

-- The longest plaintext that still fits one addon message, which is capped at 255 bytes.
-- "E1:" + 16 nonce hex + ":" + 2n cipher hex + ":" + 16 tag hex.
Crypto.MAX_PLAIN = math.floor((255 - 3 - 16 - 1 - 1 - 16) / 2)

if ns then ns.Crypto = Crypto end
return Crypto
