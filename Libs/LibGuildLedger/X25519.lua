-- X25519 key exchange, pure Lua (RFC 7748). Ported from the ChannelLab test addon, where it
-- measured 50-65 ms of work per operation in game.
--
-- A field element is 16 limbs of 16 bits. The largest intermediate, in a multiply before
-- reduction, stays near 2^44, well inside the 2^53 a Lua double holds exactly, so no bit
-- library is needed here at all.
--
-- The ladder is 255 steps. A job object runs a few steps at a time so the game can split one
-- key operation across frames; the script watchdog has tripped on long single-frame work in
-- this project before.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local X25519 = {}
local floor = math.floor

local function gf(init)
    local o = {}
    for i = 0, 15 do o[i] = 0 end
    if init then for i, v in ipairs(init) do o[i - 1] = v end end
    return o
end

local GF_121665 = gf({ 0xDB41, 1 })

local function car(o)
    for i = 0, 15 do
        local c = floor(o[i] / 65536)
        o[i] = o[i] - c * 65536
        if i < 15 then
            o[i + 1] = o[i + 1] + c
        else
            o[0] = o[0] + 38 * c
        end
    end
end

-- Swaps p and q when b is 1. Done by arithmetic rather than a branch per limb.
local function sel(p, q, b)
    for i = 0, 15 do
        local t = b * (p[i] - q[i])
        p[i] = p[i] - t
        q[i] = q[i] + t
    end
end

local function A(o, a, b) for i = 0, 15 do o[i] = a[i] + b[i] end end
local function Z(o, a, b) for i = 0, 15 do o[i] = a[i] - b[i] end end

local T = {}
local function M(o, a, b)
    for i = 0, 30 do T[i] = 0 end
    for i = 0, 15 do
        local ai = a[i]
        for j = 0, 15 do T[i + j] = T[i + j] + ai * b[j] end
    end
    for i = 0, 14 do T[i] = T[i] + 38 * T[i + 16] end
    for i = 0, 15 do o[i] = T[i] end
    car(o)
    car(o)
end

local function S(o, a) M(o, a, a) end

local function copy(a)
    local o = {}
    for i = 0, 15 do o[i] = a[i] end
    return o
end

local function inv(o, i)
    local c = copy(i)
    for a = 253, 0, -1 do
        S(c, c)
        if a ~= 2 and a ~= 4 then M(c, c, i) end
    end
    for k = 0, 15 do o[k] = c[k] end
end

local function unpack25519(s)
    local o = gf()
    for i = 0, 15 do
        o[i] = s:byte(2 * i + 1) + s:byte(2 * i + 2) * 256
    end
    o[15] = o[15] % 32768
    return o
end

local function pack25519(n)
    local t = copy(n)
    car(t); car(t); car(t)
    local m = gf()
    for _ = 1, 2 do
        m[0] = t[0] - 0xffed
        for i = 1, 14 do
            local borrow = m[i - 1] < 0 and 1 or 0
            m[i] = t[i] - 0xffff - borrow
            m[i - 1] = m[i - 1] % 65536
        end
        local borrow = m[14] < 0 and 1 or 0
        m[15] = t[15] - 0x7fff - borrow
        local b = m[15] < 0 and 1 or 0
        m[14] = m[14] % 65536
        sel(t, m, 1 - b)
    end
    local out = {}
    for i = 0, 15 do
        out[2 * i + 1] = string.char(t[i] % 256)
        out[2 * i + 2] = string.char(floor(t[i] / 256) % 256)
    end
    return table.concat(out)
end

local function clamp(k)
    local z = { k:byte(1, 32) }
    z[1] = z[1] - z[1] % 8
    local top = z[32] % 128
    if top < 64 then top = top + 64 end
    z[32] = top
    return z
end

X25519.BASE = string.char(9) .. string.rep("\0", 31)

-- A key operation that can be advanced a few ladder steps at a time.
-- scalar and point are 32-byte strings. job:step(n) returns true when finished;
-- job.result is then the 32-byte output.
function X25519.job(scalar, point)
    assert(#scalar == 32 and #point == 32, "X25519 needs 32-byte scalar and point")
    -- The Montgomery ladder exactly as RFC 7748 section 5 writes it. An earlier transcription
    -- of TweetNaCl's loop failed the RFC vectors; this one is checked against them.
    local z = clamp(scalar)
    local x1 = unpack25519(point)
    local x2, z2, x3, z3 = gf({ 1 }), gf(), copy(x1), gf({ 1 })
    local Ad, AA, B, BB, E, C, D, DA, CB, t1, t2 =
        gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
    local swap = 0
    local job = { bit = 254 }

    function job:step(n)
        local stop = math.max(-1, self.bit - n)
        for t = self.bit, stop + 1, -1 do
            local kt = floor(z[floor(t / 8) + 1] / 2 ^ (t % 8)) % 2
            local s = (swap + kt) % 2
            sel(x2, x3, s); sel(z2, z3, s)
            swap = kt
            A(Ad, x2, z2); S(AA, Ad); Z(B, x2, z2); S(BB, B); Z(E, AA, BB)
            A(C, x3, z3); Z(D, x3, z3); M(DA, D, Ad); M(CB, C, B)
            A(t1, DA, CB); S(x3, t1)
            Z(t2, DA, CB); S(t2, t2); M(z3, x1, t2)
            M(x2, AA, BB)
            M(t1, GF_121665, E); A(t1, AA, t1); M(z2, E, t1)
        end
        self.bit = stop
        if self.bit >= 0 then return false end
        sel(x2, x3, swap); sel(z2, z3, swap)
        local iz, r = gf(), gf()
        inv(iz, z2)
        M(r, x2, iz)
        self.result = pack25519(r)
        return true
    end
    return job
end

-- All at once, for tests and for anything small enough not to matter.
function X25519.scalarmult(scalar, point)
    local job = X25519.job(scalar, point)
    job:step(255)
    return job.result
end

function X25519.public(private)
    return X25519.scalarmult(private, X25519.BASE)
end

-- In game: runs the job a few steps per frame and calls done(result, milliseconds).
function X25519.async(scalar, point, done, stepsPerFrame)
    local job = X25519.job(scalar, point)
    local started = debugprofilestop and debugprofilestop() or 0
    local busy = 0
    local function tick()
        local t0 = debugprofilestop and debugprofilestop() or 0
        local finished = job:step(stepsPerFrame or 16)
        busy = busy + ((debugprofilestop and debugprofilestop() or 0) - t0)
        if finished then
            local wall = (debugprofilestop and debugprofilestop() or 0) - started
            done(job.result, busy, wall)
        else
            C_Timer.After(0, tick)
        end
    end
    tick()
end

-- The field arithmetic, shared with Ed25519 so the curve maths exists once and is tested
-- once (the RFC 7748 vectors above exercise every operation here).
X25519.field = { gf = gf, A = A, Z = Z, M = M, S = S, inv = inv, sel = sel, copy = copy, car = car,
    pack = pack25519, unpack = unpack25519 }

if ns then ns.X25519 = X25519 end
return X25519
