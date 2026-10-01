-- The game side of the secure transport, shared by both addons.
--
-- Transfer and Keys are pure: they are handed a way to send, a clock, randomness and key
-- operations. This file is where those come from in game:
--
--   GBA.Net.whisper(to, text)     an addon whisper on the transport prefix
--   GBA.Net.officers(text)        an addon message on the officer channel
--   GBA.Net.now()                 seconds, fine-grained
--   GBA.Net.random(n)             n bytes from the entropy pool, never the clock
--   GBA.Net.keyOp(s, p, done)     one X25519 operation, spread across frames
--   GBA.Net.on(kind, handler)     handler(from, text) for messages whose text starts "KIND:"
--   GBA.Net.every(frame handler)  something to run every frame (the pacer)
--
-- Both addons register their handlers here, so one frame and one prefix serve them both,
-- and when both are installed each message still reaches the addon it is meant for.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if not ns or not ns.loading then return end

local Transfer, X25519 = ns.Transfer, ns.X25519

local Net = {}
ns.Net = Net

local handlers = {}   -- kind -> list of handler(from, text)
local ticks = {}

function Net.on(kind, handler)
    handlers[kind] = handlers[kind] or {}
    table.insert(handlers[kind], handler)
end

function Net.every(fn)
    ticks[#ticks + 1] = fn
end

-- Through the router (Router.lua), the one way out. A session's pieces and its end go in the bulk
-- lane, in order; everything else on this prefix (offers to hand over, acknowledgements, asks,
-- keys) is control, so it is never stuck behind a transfer.
local BULK = { P = true, END = true }

local function route(text, dist, to)
    local tag = text:match("^(%u+):") or "?"
    ns.router:queue({ lane = BULK[tag] and "bulk" or "control", prefix = Transfer.PREFIX, text = text,
        dist = dist, target = to, kind = "x:" .. tag })
    return true
end

function Net.whisper(to, text)
    if not to or to == "" then return nil end
    return route(text, "WHISPER", to)
end

function Net.officers(text)
    return route(text, "OFFICER")
end

function Net.now()
    return (debugprofilestop and debugprofilestop() or (GetTime() * 1000)) / 1000
end

function Net.random(n)
    return ns.pool:draw(n)
end

function Net.keyOp(scalar, point, done)
    X25519.async(scalar, point, function(result) done(result) end)
end

-- Ed25519 work (signing, checking signatures, making signature keys), spread across frames.
--
-- Run whole, one signature was enough for the game to stop the addon with "script ran too
-- long": the first in-game run of role lists signed nothing, six times over. So every Ed25519
-- operation in game goes through here. fn runs inside a coroutine; Ed25519's step hook yields
-- every couple of steps, and each frame resumes jobs until about ED_BUDGET_MS have passed.
-- Jobs run one at a time, in the order they were given. done receives fn's results.
local ED_BUDGET_MS, ED_STEPS, ED_MAX_RESUMES = 8, 1, 800
local jobs, current = {}, nil

local function pack(...) return { n = select("#", ...), ... } end

function ns.edJob(fn, done)
    jobs[#jobs + 1] = { fn = fn, done = done }
end

local function runJobs()
    local clock = debugprofilestop or function() return 0 end
    local t0, resumes = clock(), 0
    while true do
        if not current then
            current = table.remove(jobs, 1)
            if not current then return end
            local fn = current.fn
            current.co = coroutine.create(function() return fn() end)
        end
        local job, count = current, 0
        ns.Ed25519.onStep = function()
            if coroutine.running() == job.co then
                count = count + 1
                if count >= ED_STEPS then count = 0; coroutine.yield() end
            end
        end
        local result = pack(coroutine.resume(job.co))
        ns.Ed25519.onStep = nil
        resumes = resumes + 1
        if coroutine.status(job.co) == "dead" then
            current = nil
            if result[1] then
                if job.done then
                    local ok, err = pcall(job.done, unpack(result, 2, result.n))
                    if not ok and ns.Print then ns.Print("|cffff4040a signature step failed:|r " .. tostring(err)) end
                end
            elseif ns.Print then
                ns.Print("|cffff4040a signature job failed:|r " .. tostring(result[2]))
            end
        end
        -- The resume cap matters where the clock does not move within a frame (the stand-in
        -- game used by tools/transport-check.lua).
        if clock() - t0 >= ED_BUDGET_MS or resumes >= ED_MAX_RESUMES then return end
    end
end

-- The name the server stamps on a message, without the realm, for this client's own realm.
local function short(name)
    if Ambiguate then return Ambiguate(name, "none") end
    return (name:match("^([^%-]+)")) or name
end
Net.short = short

-- Online guild members the officer role applies to, never this character. The role is
-- decided by Authority, so when signed role lists arrive this follows them automatically.
function ns.onlineOfficers()
    local me = UnitName("player")
    local list = {}
    for i = 1, (GetNumGuildMembers and GetNumGuildMembers() or 0) do
        local name, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
        if name and online then
            local who = short(name)
            if who ~= me and ns.Authority.may("officer", { rankIndex = rankIndex, name = who }) then
                list[#list + 1] = who
            end
        end
    end
    return list
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, prefix, text, _, sender)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(Transfer.PREFIX)
        end
        return
    end
    if prefix ~= Transfer.PREFIX or type(text) ~= "string" then return end
    local kind = text:match("^(%u+):")
    local list = kind and handlers[kind]
    if not list then return end
    local from = short(sender)
    for _, handler in ipairs(list) do
        local ok, err = pcall(handler, from, text)
        if not ok and ns.Print then ns.Print("|cffff4040transport handler failed:|r " .. tostring(err)) end
    end
end)
frame:SetScript("OnUpdate", function()
    for _, fn in ipairs(ticks) do pcall(fn) end
    local ok, err = pcall(runJobs)
    if not ok then
        ns.Ed25519.onStep = nil
        if ns.Print then ns.Print("|cffff4040signature runner failed:|r " .. tostring(err)) end
    end
end)
