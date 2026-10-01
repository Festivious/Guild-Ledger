-- The entropy pool every key is drawn from. Never the clock.
--
-- A key built from guessable inputs can be rebuilt by guessing them, however many layers of
-- locking sit on top. ChannelLab's first keys hashed the time and math.random, which is
-- exactly that. So keys come from a pool: a SHA-256 digest, stirred continuously with values
-- nobody can predict from outside this computer, and saved so it keeps growing across
-- sessions (spec: "Keys come from an entropy pool, never from the clock").
--
-- The core is pure and testable: stir, draw, export, seed. The in-game collector, which
-- samples frame and event timings, runs only in the game.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto
if ns then Crypto = ns.Crypto else Crypto = require("Crypto") end

local Entropy = {}
Entropy.__index = Entropy

-- Samples are gathered and hashed in batches, so a busy frame costs a table insert, not a hash.
Entropy.BATCH = 64

function Entropy.new()
    return setmetatable({ pool = "", samples = {}, count = 0, draws = 0 }, Entropy)
end

-- Folds everything gathered so far, plus `extra`, into the pool.
function Entropy:stir(extra)
    self.pool = Crypto.sha256(self.pool .. table.concat(self.samples, "|", 1, self.count) .. (extra or ""))
    self.count = 0
end

function Entropy:sample(value)
    self.count = self.count + 1
    self.samples[self.count] = tostring(value)
    if self.count >= Entropy.BATCH then self:stir() end
end

-- `n` bytes for a key or a nonce. Drawn through HMAC keyed by the pool, then the pool is
-- stirred again, so no two draws ever share state.
function Entropy:draw(n, extra)
    self:stir(extra)
    local out = {}
    local have = 0
    while have < n do
        self.draws = self.draws + 1
        local block = Crypto.hmac(self.pool, "draw|" .. self.draws)
        out[#out + 1] = block
        have = have + #block
    end
    self:stir("drawn|" .. self.draws)
    return table.concat(out):sub(1, n)
end

-- Hex, for saved variables. Never the draws themselves: only the pool, which a draw cannot
-- be recovered from.
function Entropy:export()
    self:stir()
    return Crypto.toHex(self.pool)
end

-- Folds a saved pool back in. Seeding never replaces what is there, so seeding from two
-- addons' saved pools only adds.
function Entropy:seed(savedHex)
    local saved = type(savedHex) == "string" and Crypto.fromHex(savedHex) or nil
    self:stir("seed|" .. (saved or ""))
end

-- The shared pool, and its collector. In game only.
if ns then
    local pool = Entropy.new()
    ns.pool = pool

    local function now() return debugprofilestop and debugprofilestop() or 0 end

    pool:stir(table.concat({
        tostring(time and time()), tostring(GetTime and GetTime()), tostring(now()),
        tostring(collectgarbage("count")), tostring(UnitGUID and UnitGUID("player")),
        tostring(math.random()),
    }, "|"))

    local collector = CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING", "UNIT_AURA",
        "CHAT_MSG_CHANNEL", "CHAT_MSG_ADDON", "COMBAT_LOG_EVENT_UNFILTERED", "BAG_UPDATE",
        "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT" }) do
        pcall(collector.RegisterEvent, collector, event)
    end
    collector:SetScript("OnEvent", function(_, event) pool:sample(event .. now()) end)
    collector:SetScript("OnUpdate", function()
        local x, y = 0, 0
        if GetCursorPosition then x, y = GetCursorPosition() end
        pool:sample(now() .. ":" .. x .. "," .. y)
    end)
end

if ns then ns.Entropy = Entropy end
return Entropy
