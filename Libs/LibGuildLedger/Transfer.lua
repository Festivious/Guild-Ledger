-- Moving a locked session from a client to an officer, by whisper. Pure: no WoW API.
--
-- Spec: docs/superpowers/specs/2026-09-23-secure-transport-design.md, "Transport" and "Crash
-- tolerance". Everything the game provides - sending, the clock, key operations, randomness,
-- storage - is passed in, so the same code runs in the LuaJIT suite and in the client.
--
-- What moves is ALREADY LOCKED with the session key before it gets here. This module adds the
-- second lock, the transport key, which exists only for one transfer: both sides make a
-- one-time key pair, swap the public halves, and each derives the same secret without it
-- ever crossing the wire.
--
-- Messages, on their own addon prefix, always by whisper:
--
--   REQ:sid:ephemeralPub:size     client -> officers   "I have a session to hand over"
--   ACC:sid:ephemeralPub          officer -> client    "send it to me"; the first one wins
--   P:sid:i:<escaped bytes>       client -> courier    piece i, transport-locked
--   END:sid:count:digest          client -> courier    that was all of it
--   NEED:sid:i,j,...              courier -> client    these pieces did not arrive; send them again
--   GOT:sid                       courier -> client    all arrived and verified
--   BAD:sid:reason                courier -> client    it did not; nothing was kept
--   ASKHOLD:sid,sid,...           client -> officers   which of these do you hold ON DISK?
--   HOLD:sid,sid,...              officer -> client    these
--
-- The rules that make it crash-tolerant:
--
--   * All or nothing. A partial transfer is never kept and never resumed; it is dropped after
--     a timeout and sent again whole. While a transfer is still going, pieces that did not
--     arrive are asked for again (NEED), a few rounds at most; a piece that fails its lock
--     still sinks the whole transfer at once.
--   * "GOT" stops the sending but the client KEEPS its copy. WoW writes saved variables only
--     on a clean logout or reload, so an officer can confirm a session and then lose it in a
--     crash before it ever reached disk.
--   * Only "HOLD" lets the client discard, and an officer lists a session in HOLD only once it
--     has come back from disk after a login or reload - the host decides that, not this module.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto, X25519
if ns then
    Crypto, X25519 = ns.Crypto, ns.X25519
else
    Crypto, X25519 = require("Crypto"), require("X25519")
end

local Transfer = {}

Transfer.PREFIX = "GuildLedgerX"
Transfer.MAX_MESSAGE = 255
Transfer.PIECE = 200              -- locked-session bytes per piece
Transfer.RATE = 4000              -- bytes per second, measured safe in game (spec: 2000-6000 held, 8000 disconnected)
Transfer.OVERHEAD = 40            -- charged per message on top of its length, as ChatThrottleLib does
Transfer.BURST = 1.0              -- seconds of rate the budget may bank
Transfer.ACCEPT_TIMEOUT = 20      -- seconds to wait for an officer to accept
Transfer.STALL_TIMEOUT = 60       -- seconds an accepted send may go without progress, or a GOT
Transfer.PARTIAL_TIMEOUT = 60     -- seconds a courier keeps a partial transfer with no new piece
Transfer.MAX_SIZE = 256 * 1024    -- refused above this; a session this large should be split
Transfer.NEED_ROUNDS = 3          -- times a courier asks for missing pieces before giving up

local function digest(blob)
    return Crypto.toHex(Crypto.sha256(blob)):sub(1, 16)
end

local function split(text, sep)
    local out = {}
    for piece in (text .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
    return out
end

-- Client side ------------------------------------------------------------------------------

local Sender = {}
Sender.__index = Sender
Transfer.Sender = Sender

-- host: {
--   send(to, text) -> result     whisper on Transfer.PREFIX; 0 or nil means accepted
--   now() -> seconds
--   random(n) -> bytes           from the entropy pool
--   keyOp(scalar, point, done)   an X25519 operation; done(result), possibly later
--   onDelivered(sid, courier)    "GOT": stop sending, keep the copy
--   onDiscard(sid)               "HOLD": an officer has it on disk; drop the copy
--   onFailed(sid, reason)        nobody accepted, or it arrived broken; retry later
-- }
function Transfer.newSender(host)
    return setmetatable({ host = host, sends = {}, queue = {}, tokens = 0, last = nil }, Sender)
end

-- Starts handing over one locked session. `officers` are the names to ask.
function Sender:offer(sid, blob, officers)
    if #blob > Transfer.MAX_SIZE then return nil, "session too large to send" end
    if self.sends[sid] then return nil, "already sending" end
    if #officers == 0 then return nil, "no officer to ask" end
    local s = { sid = sid, blob = blob, state = "asking", askedAt = self.host.now(),
        eph = self.host.random(32) }
    self.sends[sid] = s
    self.host.keyOp(s.eph, X25519.BASE, function(pub)
        s.ephPub = pub
        for _, name in ipairs(officers) do
            self.host.send(name, "REQ:" .. sid .. ":" .. Crypto.toHex(pub) .. ":" .. #blob)
        end
    end)
    return true
end

-- Pieces are sealed when they reach the front of the queue, not all here. Sealing a whole
-- session at once (14 pieces for a small one, with a fresh nonce each) was enough for the game
-- to stop the addon with "script ran too long" (2026-09-24), and nothing was sent. At the paced
-- rate only a piece or so is due each frame, so each frame seals only what it sends.
local function queuePiece(self, s, i)
    local blob, key, sid, random = s.blob, s.transportKey, s.sid, self.host.random
    self.queue[#self.queue + 1] = { to = s.courier, sid = sid, build = function()
        local piece = blob:sub((i - 1) * Transfer.PIECE + 1, i * Transfer.PIECE)
        local header = "P:" .. sid .. ":" .. i .. ":"
        local msg
        repeat
            msg = header .. Crypto.escape(Crypto.sealRaw(key, piece, random(Crypto.NONCE_BYTES)))
        until #msg <= Transfer.MAX_MESSAGE
        return msg
    end }
end

local function queueEnd(self, s)
    local count, blob, sid = math.ceil(#s.blob / Transfer.PIECE), s.blob, s.sid
    self.queue[#self.queue + 1] = { to = s.courier, sid = sid, build = function()
        return "END:" .. sid .. ":" .. count .. ":" .. digest(blob)
    end }
end

local function queuePieces(self, s)
    for i = 1, math.ceil(#s.blob / Transfer.PIECE) do queuePiece(self, s, i) end
    queueEnd(self, s)
    s.state = "sending"
end

-- At most this many queued messages are sealed in one call to pump.
Transfer.BUILDS_PER_PUMP = 2

-- Sends what the byte budget allows. Call often; in game, every frame.
function Sender:pump()
    local t = self.host.now()
    if self.last then
        self.tokens = math.min(Transfer.RATE * Transfer.BURST, self.tokens + (t - self.last) * Transfer.RATE)
    end
    self.last = t

    local builds = 0
    while self.queue[1] do
        local item = self.queue[1]
        if not item.text then
            if builds >= Transfer.BUILDS_PER_PUMP then break end
            builds = builds + 1
            item.text = item.build()
            item.build = nil
        end
        local cost = #item.text + Transfer.OVERHEAD
        if self.tokens < cost then break end
        local s = self.sends[item.sid]
        if s and s.state == "sending" then
            self.host.send(item.to, item.text)
            self.tokens = self.tokens - cost
            s.progressAt = t
        end
        table.remove(self.queue, 1)
    end

    for sid, s in pairs(self.sends) do
        -- Nobody accepted in time: the send becomes a pending request, retried later.
        if s.state == "asking" and t - s.askedAt > Transfer.ACCEPT_TIMEOUT then
            self.sends[sid] = nil
            if self.host.onFailed then self.host.onFailed(sid, "no officer accepted") end
        -- Accepted, then nothing moved: no piece went and no GOT came back. Seen in game when
        -- sealing was stopped by "script ran too long" and the send sat half-made for good.
        -- Given up and offered again later, like a send nobody accepted.
        elseif (s.state == "keying" or s.state == "sending")
            and t - (s.progressAt or s.askedAt or t) > Transfer.STALL_TIMEOUT then
            self.sends[sid] = nil
            for i = #self.queue, 1, -1 do
                if self.queue[i].sid == sid then table.remove(self.queue, i) end
            end
            if self.host.onFailed then self.host.onFailed(sid, "the transfer stalled") end
        end
    end
end

function Sender:pending()
    return #self.queue
end

-- Asks officers which of these sessions they hold on disk. Call at every sync moment.
function Sender:askHolding(sids, officers)
    if #sids == 0 then return end
    local list = table.concat(sids, ",")
    for _, name in ipairs(officers) do self.host.send(name, "ASKHOLD:" .. list) end
end

function Sender:handle(from, text)
    local kind, rest = text:match("^(%u+):(.*)$")
    if kind == "ACC" then
        local sid, pubHex = rest:match("^(%x+):(%x+)$")
        local s = sid and self.sends[sid]
        if not s or s.state ~= "asking" then return end   -- a second officer; the first won
        local pub = Crypto.fromHex(pubHex)
        if not pub or #pub ~= 32 then return end
        s.state, s.courier = "keying", from
        s.progressAt = self.host.now()
        self.host.keyOp(s.eph, pub, function(shared)
            s.transportKey = Crypto.hmac(shared, "transport|" .. sid)
            s.eph = nil
            queuePieces(self, s)
        end)
    elseif kind == "NEED" then
        -- Only the pieces that did not arrive, then the end again.
        local sid, list = rest:match("^(%x+):([%d,]+)$")
        local s = sid and self.sends[sid]
        if not s or from ~= s.courier or s.state ~= "sending" then return end
        local count = math.ceil(#s.blob / Transfer.PIECE)
        for _, i in ipairs(split(list, ",")) do
            i = tonumber(i)
            if i and i >= 1 and i <= count then queuePiece(self, s, i) end
        end
        queueEnd(self, s)
        s.progressAt = self.host.now()
    elseif kind == "GOT" then
        local sid = rest:match("^(%x+)$")
        local s = sid and self.sends[sid]
        if not s or from ~= s.courier then return end
        -- Delivered, not safe: the copy is kept until an officer says HOLD.
        self.sends[sid] = nil
        if self.host.onDelivered then self.host.onDelivered(sid, from) end
    elseif kind == "BAD" then
        local sid, reason = rest:match("^(%x+):?(.*)$")
        local s = sid and self.sends[sid]
        if not s or from ~= s.courier then return end
        self.sends[sid] = nil
        if self.host.onFailed then self.host.onFailed(sid, "courier refused it: " .. reason) end
    elseif kind == "HOLD" then
        for _, sid in ipairs(split(rest, ",")) do
            if sid:match("^%x+$") and self.host.onDiscard then self.host.onDiscard(sid, from) end
        end
    end
end

-- Officer side ------------------------------------------------------------------------------

local Receiver = {}
Receiver.__index = Receiver
Transfer.Receiver = Receiver

-- host: {
--   send(to, text), now(), random(n), keyOp(scalar, point, done)
--   accept(from, sid, size) -> bool     may this client hand over this session?
--   onReceived(sid, from, blob)         every piece arrived and verified; keep the locked blob
--   holdingOnDisk(from, sids) -> list   which of these sids are held AND came back from disk
-- }
function Transfer.newReceiver(host)
    return setmetatable({ host = host, inbound = {} }, Receiver)
end

function Receiver:handle(from, text)
    local kind, rest = text:match("^(%u+):(.*)$")
    if kind == "REQ" then
        local sid, pubHex, size = rest:match("^(%x+):(%x+):(%d+)$")
        size = tonumber(size)
        if not sid or not size or size > Transfer.MAX_SIZE then return end
        if self.inbound[sid] then return end
        if self.host.accept and not self.host.accept(from, sid, size) then return end
        local pub = Crypto.fromHex(pubHex)
        if not pub or #pub ~= 32 then return end
        local c = { from = from, size = size, pieces = {}, got = 0, touched = self.host.now() }
        self.inbound[sid] = c
        local eph = self.host.random(32)
        self.host.keyOp(eph, X25519.BASE, function(ephPub)
            self.host.keyOp(eph, pub, function(shared)
                c.transportKey = Crypto.hmac(shared, "transport|" .. sid)
                self.host.send(from, "ACC:" .. sid .. ":" .. Crypto.toHex(ephPub))
            end)
        end)
    elseif kind == "P" then
        local sid, i, body = rest:match("^(%x+):(%d+):(.*)$")
        local c = sid and self.inbound[sid]
        if not c or c.from ~= from or not c.transportKey then return end
        i = tonumber(i)
        c.touched = self.host.now()
        if c.pieces[i] then return end
        local piece = Crypto.openRaw(c.transportKey, Crypto.unescape(body))
        if not piece then
            c.broken = true
            return
        end
        c.pieces[i] = piece
        c.got = c.got + 1
    elseif kind == "END" then
        local sid, count, want = rest:match("^(%x+):(%d+):(%x+)$")
        local c = sid and self.inbound[sid]
        if not c or c.from ~= from then return end
        count = tonumber(count)
        -- Pieces that did not arrive are asked for again, while the sender is still there: a few
        -- rounds, as many as fit in one message each time.
        if not c.broken and c.got < count and (c.needs or 0) < Transfer.NEED_ROUNDS then
            local missing, text = {}, "NEED:" .. sid .. ":"
            for k = 1, count do
                if not c.pieces[k] then
                    local more = (#missing > 0 and "," or "") .. k
                    if #text + #more > Transfer.MAX_MESSAGE then break end
                    text = text .. more
                    missing[#missing + 1] = k
                end
            end
            c.needs = (c.needs or 0) + 1
            c.touched = self.host.now()
            return self.host.send(from, text)
        end
        self.inbound[sid] = nil
        -- All or nothing: anything short, broken or not matching the digest is dropped whole.
        if c.broken then return self.host.send(from, "BAD:" .. sid .. ":a piece failed its lock") end
        if c.got ~= count then return self.host.send(from, "BAD:" .. sid .. ":" .. c.got .. " of " .. count .. " pieces") end
        local parts = {}
        for k = 1, count do
            if not c.pieces[k] then return self.host.send(from, "BAD:" .. sid .. ":piece " .. k .. " missing") end
            parts[k] = c.pieces[k]
        end
        local blob = table.concat(parts)
        if digest(blob) ~= want then return self.host.send(from, "BAD:" .. sid .. ":digest does not match") end
        if self.host.onReceived then self.host.onReceived(sid, from, blob) end
        self.host.send(from, "GOT:" .. sid)
    elseif kind == "ASKHOLD" then
        local asked = {}
        for _, sid in ipairs(split(rest, ",")) do
            if sid:match("^%x+$") then asked[#asked + 1] = sid end
        end
        local held = self.host.holdingOnDisk and self.host.holdingOnDisk(from, asked) or {}
        if #held > 0 then self.host.send(from, "HOLD:" .. table.concat(held, ",")) end
    end
end

-- Drops partial transfers that stopped arriving. Call periodically.
function Receiver:sweep()
    local t = self.host.now()
    for sid, c in pairs(self.inbound) do
        if t - c.touched > Transfer.PARTIAL_TIMEOUT then self.inbound[sid] = nil end
    end
end

if ns then ns.Transfer = Transfer end
return Transfer
