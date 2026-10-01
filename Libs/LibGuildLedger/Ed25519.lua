-- Ed25519 signatures (RFC 8032) and the SHA-512 they need. Pure Lua, no WoW API.
--
-- Signing is what lets the guild master's role list be carried by anyone: the list is signed
-- once with the guild master's private key, and every client checks it against the public key
-- it pinned, whoever handed it over (spec: "Access control: the guild master role key").
--
-- The curve arithmetic is X25519's (same field, same 16-limb representation), shared rather
-- than copied. Ported from TweetNaCl's structure. The RFC 8032 and FIPS 180-4 vectors in
-- tests/test_ed25519.lua are what make this trustworthy; the port was written from memory.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto, X25519
if ns then
    Crypto, X25519 = ns.Crypto, ns.X25519
else
    Crypto, X25519 = require("Crypto"), require("X25519")
end

local Ed25519 = {}
local floor = math.floor

-- Called at each step of the long loops. Nil in tests, so everything runs at once. In game the
-- job runner (Net.lua, ns.edJob) sets it to yield, so one signature or check spreads across
-- frames: run whole, the game stopped it with "script ran too long" (first seen signing a role
-- list, 2026-09-24).
Ed25519.onStep = nil
local function step()
    local f = Ed25519.onStep
    if f then f() end
end
local MOD = 4294967296

-- SHA-512 ------------------------------------------------------------------------------
--
-- 64-bit words as (hi, lo) pairs of 32-bit numbers, because a Lua double holds 53 bits.

local K = {
    0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc,
    0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019, 0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
    0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
    0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
    0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3, 0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65,
    0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
    0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4,
    0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725, 0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
    0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
    0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
    0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001, 0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30,
    0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
    0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8,
    0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb, 0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
    0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
    0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
    0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207, 0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178,
    0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
    0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c,
    0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a, 0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
}

local H0 = {
    0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, 0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
    0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f, 0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
}

local function word(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function bytes32(n)
    return string.char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

function Ed25519.sha512(msg)
    local b = Crypto.bitops()
    local band, bor, bxor, bnot, rshift, lshift = b.band, b.bor, b.bxor, b.bnot, b.rshift, b.lshift

    -- Rotate right the 64-bit (hi, lo) by n, for 0 < n < 64 and n ~= 32.
    local function rotr(hi, lo, n)
        if n < 32 then
            return bor(rshift(hi, n), lshift(lo, 32 - n)), bor(rshift(lo, n), lshift(hi, 32 - n))
        end
        n = n - 32
        return bor(rshift(lo, n), lshift(hi, 32 - n)), bor(rshift(hi, n), lshift(lo, 32 - n))
    end
    local function shr(hi, lo, n)
        return rshift(hi, n), bor(rshift(lo, n), lshift(hi, 32 - n))
    end
    local function add(ah, al, bh, bl)
        local lo = al + bl
        return (ah + bh + floor(lo / MOD)) % MOD, lo % MOD
    end

    local h = {}
    for i = 1, 16 do h[i] = H0[i] end

    local bits = #msg * 8
    msg = msg .. "\128" .. string.rep("\0", (111 - #msg) % 128)
        .. string.rep("\0", 8) .. bytes32(floor(bits / MOD)) .. bytes32(bits % MOD)

    local wh, wl = {}, {}
    for chunk = 1, #msg, 128 do
        step()
        for t = 0, 15 do
            wh[t] = word(msg, chunk + t * 8)
            wl[t] = word(msg, chunk + t * 8 + 4)
        end
        for t = 16, 79 do
            local h1, l1 = rotr(wh[t - 15], wl[t - 15], 1)
            local h2, l2 = rotr(wh[t - 15], wl[t - 15], 8)
            local h3, l3 = shr(wh[t - 15], wl[t - 15], 7)
            local s0h, s0l = bxor(bxor(h1, h2), h3), bxor(bxor(l1, l2), l3)
            h1, l1 = rotr(wh[t - 2], wl[t - 2], 19)
            h2, l2 = rotr(wh[t - 2], wl[t - 2], 61)
            h3, l3 = shr(wh[t - 2], wl[t - 2], 6)
            local s1h, s1l = bxor(bxor(h1, h2), h3), bxor(bxor(l1, l2), l3)
            local th, tl = add(wh[t - 16], wl[t - 16], s0h, s0l)
            th, tl = add(th, tl, wh[t - 7], wl[t - 7])
            wh[t], wl[t] = add(th, tl, s1h, s1l)
        end

        local ah, al, bh, bl, ch, cl, dh, dl = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        local eh, el, fh, fl, gh, gl, hh, hl = h[9], h[10], h[11], h[12], h[13], h[14], h[15], h[16]
        for t = 0, 79 do
            local r1h, r1l = rotr(eh, el, 14)
            local r2h, r2l = rotr(eh, el, 18)
            local r3h, r3l = rotr(eh, el, 41)
            local S1h, S1l = bxor(bxor(r1h, r2h), r3h), bxor(bxor(r1l, r2l), r3l)
            local chh = bxor(band(eh, fh), band(bnot(eh), gh))
            local chl = bxor(band(el, fl), band(bnot(el), gl))
            local t1h, t1l = add(hh, hl, S1h, S1l)
            t1h, t1l = add(t1h, t1l, chh, chl)
            t1h, t1l = add(t1h, t1l, K[t * 2 + 1], K[t * 2 + 2])
            t1h, t1l = add(t1h, t1l, wh[t], wl[t])
            r1h, r1l = rotr(ah, al, 28)
            r2h, r2l = rotr(ah, al, 34)
            r3h, r3l = rotr(ah, al, 39)
            local S0h, S0l = bxor(bxor(r1h, r2h), r3h), bxor(bxor(r1l, r2l), r3l)
            local mjh = bxor(bxor(band(ah, bh), band(ah, ch)), band(bh, ch))
            local mjl = bxor(bxor(band(al, bl), band(al, cl)), band(bl, cl))
            local t2h, t2l = add(S0h, S0l, mjh, mjl)
            hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
            eh, el = add(dh, dl, t1h, t1l)
            dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
            ah, al = add(t1h, t1l, t2h, t2l)
        end
        local vals = { ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
        for i = 1, 16, 2 do
            h[i], h[i + 1] = add(h[i], h[i + 1], vals[i], vals[i + 1])
        end
    end

    local out = {}
    for i = 1, 16 do out[i] = bytes32(h[i]) end
    return table.concat(out)
end

-- Curve ----------------------------------------------------------------------------------

local F = X25519.field
local gf, A, Z, M, S, inv, sel, copy = F.gf, F.A, F.Z, F.M, F.S, F.inv, F.sel, F.copy
local pack25519, unpack25519 = F.pack, F.unpack

local gf0 = gf()
local gf1 = gf({ 1 })

local function par(a) return pack25519(a):byte(1) % 2 end
local function neq(a, b) return pack25519(a) ~= pack25519(b) end

local function pow2523(i)
    local c = copy(i)
    for a = 250, 0, -1 do
        if a % 8 == 0 then step() end
        S(c, c)
        if a ~= 1 then M(c, c, i) end
    end
    return c
end

-- Constants, derived rather than typed: d = -121665/121666, 2d, sqrt(-1).
local D, D2, I
do
    local n, den, t = gf(), gf(), gf()
    Z(n, gf0, gf({ 0xDB41, 1 }))            -- -121665
    inv(den, gf({ 0xDB42, 1 }))             -- 1/121666
    D = gf(); M(D, n, den)
    D2 = gf(); A(D2, D, D)
    -- sqrt(-1) = 2^((p-1)/4), where (p-1)/4 = 2^253 - 5: every bit set but bit 2.
    local r = gf({ 1 })
    local two = gf({ 2 })
    for bit = 252, 0, -1 do
        S(r, r)
        if bit ~= 2 then M(r, r, two) end
    end
    I = r
end

local function point() return { gf(), gf(), gf(), gf() } end

local function add(p, q)
    local a, b, c, d, t, e, f, g, h = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
    Z(a, p[2], p[1]); Z(t, q[2], q[1]); M(a, a, t)
    A(b, p[1], p[2]); A(t, q[1], q[2]); M(b, b, t)
    M(c, p[4], q[4]); M(c, c, D2)
    M(d, p[3], q[3]); A(d, d, d)
    Z(e, b, a); Z(f, d, c); A(g, d, c); A(h, b, a)
    M(p[1], e, f); M(p[2], h, g); M(p[3], g, f); M(p[4], e, h)
end

local function cswap(p, q, b)
    for i = 1, 4 do sel(p[i], q[i], b) end
end

local function packPoint(p)
    local zi, tx, ty = gf(), gf(), gf()
    inv(zi, p[3])
    M(tx, p[1], zi)
    M(ty, p[2], zi)
    local s = pack25519(ty)
    local last = s:byte(32) + par(tx) * 128
    return s:sub(1, 31) .. string.char(last)
end

-- s: a 32-byte string.
local function scalarmult(q, s)
    local p = { gf(), gf({ 1 }), gf({ 1 }), gf() }
    for i = 255, 0, -1 do
        step()
        local b = floor(s:byte(floor(i / 8) + 1) / 2 ^ (i % 8)) % 2
        cswap(p, q, b)
        add(q, p)
        add(p, p)
        cswap(p, q, b)
    end
    return p
end

-- Decodes a point and negates it, as verification wants -A. nil if it is not on the curve.
local function unpackneg(s)
    local r = point()
    local num, den, den2, den4, den6, t, chk = gf(), gf(), gf(), gf(), gf(), gf(), gf()
    r[3] = copy(gf1)
    r[2] = unpack25519(s)
    S(num, r[2]); M(den, num, D); Z(num, num, r[3]); A(den, r[3], den)
    S(den2, den); S(den4, den2); M(den6, den4, den2); M(t, den6, num); M(t, t, den)
    t = pow2523(t)
    M(t, t, num); M(t, t, den); M(t, t, den); M(r[1], t, den)
    S(chk, r[1]); M(chk, chk, den)
    if neq(chk, num) then M(r[1], r[1], I) end
    S(chk, r[1]); M(chk, chk, den)
    if neq(chk, num) then return nil end
    if par(r[1]) == floor(s:byte(32) / 128) then Z(r[1], gf0, r[1]) end
    M(r[4], r[1], r[2])
    return r
end

-- The base point, decoded from its standard encoding (y = 4/5, x even) and negated back.
local BASE
do
    local negB = unpackneg(string.char(0x58) .. string.rep(string.char(0x66), 31))
    BASE = { gf(), copy(negB[2]), copy(negB[3]), gf() }
    Z(BASE[1], gf0, negB[1])
    M(BASE[4], BASE[1], BASE[2])
end

local function scalarbase(s)
    return scalarmult({ copy(BASE[1]), copy(BASE[2]), copy(BASE[3]), copy(BASE[4]) }, s)
end

-- Scalars mod L -------------------------------------------------------------------------

local L = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }

-- x: a 0-indexed array of 64 numbers. Returns 32 bytes, x mod L.
local function modL(x)
    for i = 63, 32, -1 do
        local carry = 0
        local j = i - 32
        while j < i - 12 do
            x[j] = x[j] + carry - 16 * x[i] * L[j - (i - 32) + 1]
            carry = floor((x[j] + 128) / 256)
            x[j] = x[j] - carry * 256
            j = j + 1
        end
        x[j] = x[j] + carry
        x[i] = 0
    end
    local carry = 0
    for j = 0, 31 do
        x[j] = x[j] + carry - floor(x[31] / 16) * L[j + 1]
        carry = floor(x[j] / 256)
        x[j] = x[j] % 256
    end
    for j = 0, 31 do x[j] = x[j] - carry * L[j + 1] end
    local out = {}
    for i = 0, 31 do
        x[i + 1] = (x[i + 1] or 0) + floor(x[i] / 256)
        out[i + 1] = string.char(x[i] % 256)
    end
    return table.concat(out)
end

local function reduce(h64)
    local x = {}
    for i = 0, 63 do x[i] = h64:byte(i + 1) end
    return modL(x)
end

local function clamp(d)
    local first = d:byte(1)
    first = first - first % 8
    local last = d:byte(32) % 128
    if last < 64 then last = last + 64 end
    return string.char(first) .. d:sub(2, 31) .. string.char(last)
end

-- API ------------------------------------------------------------------------------------

-- The public key for a 32-byte secret seed.
function Ed25519.publicKey(seed)
    assert(#seed == 32, "an Ed25519 seed is 32 bytes")
    local d = Ed25519.sha512(seed)
    return packPoint(scalarbase(clamp(d:sub(1, 32))))
end

-- A 64-byte signature of `msg`.
function Ed25519.sign(msg, seed, public)
    public = public or Ed25519.publicKey(seed)
    local d = Ed25519.sha512(seed)
    local a = clamp(d:sub(1, 32))
    local r = reduce(Ed25519.sha512(d:sub(33, 64) .. msg))
    local R = packPoint(scalarbase(r))
    local h = reduce(Ed25519.sha512(R .. public .. msg))
    local x = {}
    for i = 0, 63 do x[i] = 0 end
    for i = 0, 31 do x[i] = r:byte(i + 1) end
    for i = 0, 31 do
        local hi = h:byte(i + 1)
        for j = 0, 31 do x[i + j] = x[i + j] + hi * a:byte(j + 1) end
    end
    return R .. modL(x)
end

-- true when `sig` is `public`'s signature of `msg`. Anything malformed is refused.
function Ed25519.verify(sig, msg, public)
    if type(sig) ~= "string" or #sig ~= 64 or type(public) ~= "string" or #public ~= 32 then return false end
    -- S must be below L, or the signature could be altered without the key (malleability).
    local s = sig:sub(33, 64)
    for i = 32, 1, -1 do
        local sb, lb = s:byte(i), L[i]
        if sb < lb then break end
        if sb > lb then return false end
        if i == 1 then return false end
    end
    local q = unpackneg(public)
    if not q then return false end
    local h = reduce(Ed25519.sha512(sig:sub(1, 32) .. public .. msg))
    local p = scalarmult(q, h)
    add(p, scalarbase(s))
    return packPoint(p) == sig:sub(1, 32)
end

if ns then ns.Ed25519 = Ed25519 end
return Ed25519
