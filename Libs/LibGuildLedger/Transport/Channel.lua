-- Addon-channel transport: chunked send over ChatThrottleLib, reassembly on receive.
--
-- ONE prefix, always. Blizzard's throttle is per registered prefix - roughly 10 messages
-- refilling at 1/sec, about 215 bytes of payload per second - and splitting a transfer
-- across several prefixes to multiply that is a documented way to get disconnected.
--
-- Delivery is fire and forget: guild addon messages reach only players who are online
-- right now, and nothing is queued for anyone else. That is survivable here because
-- merging is idempotent, so a failed transfer costs only the bytes to send it again.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Framing = ns.Framing

local Channel = {}

Channel.PREFIX = "GuildLedger"
Channel.PRIORITY = "BULK"

local reassembler = Framing.Reassembler.new()
local handlers = {}
local outbound = { active = 0 }

function Channel.registerHandler(fn)
    if type(fn) == "function" then handlers[#handlers + 1] = fn end
end

local function deliver(sender, payload)
    for _, handler in ipairs(handlers) do
        pcall(handler, sender, payload)
    end
end

-- Returns partCount, estimatedSeconds, or nil plus a reason. Goes through the router
-- (Router.lua), then ChatThrottleLib. opts: lane ("records" unless said), kind (for the router's
-- counts), key (a message waiting with the same key and recipient is replaced by this one; only
-- for a message of one part).
function Channel.send(encodedPayload, distribution, target, opts)
    opts = opts or {}
    if type(encodedPayload) ~= "string" or #encodedPayload == 0 then
        return nil, "nothing to send"
    end
    if not (ns and ns.router) then
        return nil, "the router is unavailable"
    end

    local transferID = Framing.newTransferID()
    local parts, err = Framing.split(encodedPayload, transferID)
    if not parts then return nil, err end

    -- A single named queue keeps the parts of one transfer in order relative to each
    -- other without starving anything else the client is sending.
    local queueName = "GuildLedger-" .. transferID
    outbound.active = outbound.active + 1

    for _, message in ipairs(parts) do
        ns.router:queue({ lane = opts.lane or "records", prefix = Channel.PREFIX, text = message,
            dist = distribution or "GUILD", target = target, kind = opts.kind or "channel",
            key = #parts == 1 and opts.key or nil, viaThrottle = true, queueName = queueName })
    end

    -- At the enforced ceiling rather than the library's own softer limit.
    local seconds = #encodedPayload / 215
    return #parts, seconds
end

function Channel.pendingTransfers()
    return reassembler:pendingCount()
end

function Channel.prune(now)
    return reassembler:prune(now)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(_, event, prefix, message, _, sender)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(Channel.PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(Channel.PREFIX)
        end
        return
    end

    if prefix ~= Channel.PREFIX then return end

    local payload = reassembler:accept(sender, message, time())
    if payload then deliver(sender, payload) end
end)

-- Stalled transfers are dropped rather than held forever; the sender can simply resend.
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(60, function() reassembler:prune(time()) end)
end

if ns then ns.Channel = Channel end
return Channel
