-- The one way out: every addon message this client sends goes through here.
--
-- Spec: docs/superpowers/specs/2026-09-24-guild-propagation-and-soak-design.md, part 3.
--
-- - Three lanes, sent in order of priority: control (acknowledgements, summaries, asks, keys),
--   then records (offers, claims, decisions), then bulk (session pieces). Within a lane, first
--   in, first out, so the pieces of one message keep their order. A small "got it" is never
--   stuck behind a forty-piece transfer, where its lateness would make the other side resend.
-- - Merging: a message queued with a key replaces one still waiting with the same key and
--   recipient, so a busy client sends the newest, once, instead of every version.
-- - Pacing: one byte budget for everything this client sends, so nothing is dropped by the
--   server and other addons keep their share. The guild and officer channels also have a count
--   limit, measured in game (/gba burst, 2026-09-24): a burst of 10 addon messages per prefix, then
--   the rest answered 3 (throttled) and dropped. Each prefix's channel messages wait for their
--   own count; whispers behind them are not held up.
-- - A throttled answer puts the message back at the front of its line, never loses it.
-- - A small log: counts per lane and kind, and the last messages sent, never growing.
--
-- The core is pure: it is handed a send function and a clock. The game side at the bottom makes
-- the one instance, ns.router, and pumps it every frame.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Router = {}
Router.__index = Router

Router.LANES = { "control", "records", "bulk" }
Router.RATE = 4000        -- bytes a second; whispers held at 2000-6000 in game and 8000 disconnected
Router.BURST = 1.0        -- seconds of rate the budget may bank
Router.OVERHEAD = 40      -- charged per message on top of its length, as ChatThrottleLib does
Router.LOG_SIZE = 200
Router.CHANNEL_BURST = 10  -- guild or officer channel messages a prefix may send at once (measured)
Router.CHANNEL_REFILL = 1  -- a second (measured: 30 at 1/s all went; at 2/s, 24 of 30)
Router.THROTTLED = 3       -- what the game answers a message it refused for sending too fast

local CHANNELS = { GUILD = true, OFFICER = true, RAID = true, PARTY = true }
Router.CHANNELS = CHANNELS

-- opts: send(item) -> nothing; now() -> seconds; rate, burst, overhead (optional)
function Router.new(opts)
    local r = setmetatable({
        send = opts.send, now = opts.now,
        rate = opts.rate or Router.RATE, burst = opts.burst or Router.BURST, overhead = opts.overhead or Router.OVERHEAD,
        lanes = {}, tokens = 0, last = nil,
        counts = {}, merged = 0, throttled = 0, log = {}, logNext = 1, buckets = {},
    }, Router)
    for _, lane in ipairs(Router.LANES) do r.lanes[lane] = {} end
    r.tokens = r.rate * r.burst
    return r
end

-- Queues one message. item: { lane, prefix, text, dist, target, kind, key }. A key replaces a
-- queued item with the same key and target in the same lane, keeping its place in line.
function Router:queue(item)
    local lane = self.lanes[item.lane or "records"]
    assert(lane, "no such lane: " .. tostring(item.lane))
    item.lane = item.lane or "records"
    if item.key then
        for _, q in ipairs(lane) do
            if q.key == item.key and q.target == item.target and q.dist == item.dist then
                q.text, q.prefix, q.kind = item.text, item.prefix, item.kind
                self.merged = self.merged + 1
                return q
            end
        end
    end
    lane[#lane + 1] = item
    return item
end

function Router:waiting(lane)
    if lane then return #self.lanes[lane] end
    local n = 0
    for _, l in pairs(self.lanes) do n = n + #l end
    return n
end

local function record(self, item, t)
    local kind = item.kind or "?"
    local c = self.counts[item.lane .. ":" .. kind] or 0
    self.counts[item.lane .. ":" .. kind] = c + 1
    self.log[self.logNext] = { t = t, lane = item.lane, kind = kind, to = item.target or item.dist, bytes = #item.text }
    self.logNext = self.logNext % Router.LOG_SIZE + 1
end

-- A prefix's count of guild or officer channel messages it may send now, refilled over time.
local function bucket(self, item, t)
    if not CHANNELS[item.dist] then return nil end
    local key = tostring(item.prefix)
    local b = self.buckets[key]
    if not b then
        b = { n = Router.CHANNEL_BURST, last = t }
        self.buckets[key] = b
    end
    b.n = math.min(Router.CHANNEL_BURST, b.n + (t - b.last) * Router.CHANNEL_REFILL)
    b.last = t
    return b
end

-- Sends what the budget allows, highest lane first. Call often; in game, every frame.
function Router:pump()
    local t = self.now()
    if self.last then
        self.tokens = math.min(self.rate * self.burst, self.tokens + (t - self.last) * self.rate)
    end
    self.last = t
    for _, name in ipairs(Router.LANES) do
        local lane = self.lanes[name]
        local i = 1
        while lane[i] do
            local item = lane[i]
            local b = bucket(self, item, t)
            if b and b.n < 1 then
                -- This prefix's channel count is spent: its messages wait, in order; others go.
                i = i + 1
            else
                local cost = #item.text + self.overhead
                -- A higher lane still waiting holds the lower ones back, so order across lanes
                -- is kept even when the budget runs short.
                if self.tokens < cost then return end
                table.remove(lane, i)
                self.tokens = self.tokens - cost
                if b then b.n = b.n - 1 end
                if self.send(item) == Router.THROTTLED then
                    -- Refused for going too fast: back to the front of its place, never lost.
                    table.insert(lane, i, item)
                    self.throttled = self.throttled + 1
                    self.tokens = self.tokens + cost
                    if not b then break end        -- a whisper refused: this lane waits
                    b.n = 0
                    i = i + 1
                else
                    record(self, item, t)
                end
            end
        end
    end
end

-- The last messages sent, oldest first.
function Router:recent()
    local out = {}
    for i = 0, Router.LOG_SIZE - 1 do
        local e = self.log[(self.logNext - 1 + i) % Router.LOG_SIZE + 1]
        if e then out[#out + 1] = e end
    end
    return out
end

-- The game side: the one instance, sending through ChatThrottleLib where it is loaded (so other
-- addons keep their share of the player's budget) and pumped every frame.
if ns then
    local PRIORITY = { control = "ALERT", records = "NORMAL", bulk = "BULK" }
    local function now()
        return (debugprofilestop and debugprofilestop() or (GetTime() * 1000)) / 1000
    end
    ns.router = Router.new({
        now = now,
        -- Guild and officer channel messages go straight to the game, paced here by count and
        -- their answer read: ChatThrottleLib paces bytes, not the channel's count, and does not
        -- say when the game refused one. Whispers of records go through it.
        send = function(item)
            if ChatThrottleLib and item.viaThrottle and not CHANNELS[item.dist] then
                ChatThrottleLib:SendAddonMessage(PRIORITY[item.lane], item.prefix, item.text, item.dist, item.target,
                    item.queueName)
                return 0
            end
            return C_ChatInfo.SendAddonMessage(item.prefix, item.text, item.dist, item.target)
        end,
    })
    local frame = CreateFrame("Frame")
    frame:SetScript("OnUpdate", function() ns.router:pump() end)
    ns.Router = Router
end

return Router
