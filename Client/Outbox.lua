-- The client's outbox: sessions on their way to the officers.
--
-- Spec: docs/superpowers/specs/2026-09-23-secure-transport-design.md.
--
--   1. A session is crunched, then locked with a brand-new session key.
--   2. The session key is locked into a letter for each reader the reward names, and then
--      forgotten. From here on only those letters can open the session.
--   3. The locked session goes, by whisper, to whichever online officer accepts first.
--   4. "Got it": the courier has every piece. The client stops sending but KEEPS its copy.
--   5. "Holding it": an officer has it back from disk after a reload. Only now is the copy
--      deleted.
--
-- If no officer is online, the session waits, still locked, and is offered again at the next
-- sync moment: login, reload, or a zone change. Nothing here ever holds another player's data.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Crypto, Keys, Transfer, Codec, Net = GBA.Crypto, GBA.Keys, GBA.Transfer, GBA.Codec, GBA.Net

local Outbox = {}
ns.Outbox = Outbox

Outbox.SYNC_INTERVAL = 60      -- seconds between automatic syncs, however often zones change

-- Saved per account, keyed by character, because a session belongs to the character who
-- played it.
local store = {}
ns.persistAccount("outbox", function() return store end, function(saved)
    if type(saved) ~= "table" then return end
    store = saved
    -- A session in flight when the game closed: the send died with the old session, so it is
    -- offered again. Left as "offered", nothing ever picked it up (seen 2026-09-24).
    --
    -- A session still locking or held was locked for a claim whose mail was never sent: a
    -- prepared claim does not outlive the session it was prepared in. It never left and never
    -- will, so it is deleted rather than kept in the file for good (docs/fix-plan.md, I11, P5).
    for _, entries in pairs(store) do
        if type(entries) == "table" then
            for sid, e in pairs(entries) do
                if type(e) == "table" and e.state == "offered" then e.state = "pending" end
                if type(e) == "table" and (e.state == "held" or e.state == "locking") then entries[sid] = nil end
            end
        end
    end
end)

local directory = Keys.newDirectory()
ns.persistAccount("directory", function() return directory:export() end,
    function(saved) directory = Keys.newDirectory(saved) end)

function Outbox.directory() return directory end

local function mine()
    local me = UnitName("player") or "?"
    store[me] = store[me] or {}
    return store[me]
end

function Outbox.entries() return mine() end

-- Keys ------------------------------------------------------------------------------------

-- An officer's key, from the officer themselves (on the officer channel) or relayed by one.
Net.on("PUB", function(from, text)
    local pub = text:match("^PUB:(%x+)$")
    if pub then directory:learn(from, pub, from) end
end)
Net.on("KEY", function(from, text)
    local name, pub = text:match("^KEY:([^:]+):(%x+)$")
    if name then directory:learn(name, pub, from) end
end)

function Outbox.requestKeys()
    for _, name in ipairs(GBA.onlineOfficers()) do Net.whisper(name, "KEYREQ:") end
end

-- Sending ---------------------------------------------------------------------------------

local sender = Transfer.newSender({
    send = Net.whisper, now = Net.now, random = Net.random, keyOp = Net.keyOp,
    onDelivered = function(sid, courier)
        local e = mine()[sid]
        if not e then return end
        e.state, e.courier = "delivered", courier
        GBA.Print(string.format("session %s delivered to %s; kept until an officer confirms it is saved", sid, courier))
    end,
    onDiscard = function(sid, from)
        local e = mine()[sid]
        if not e or not e.blob then return end
        -- The session data goes. Key letters not yet mailed stay until they are: losing one
        -- would leave that reader unable to open a session they were meant to read.
        e.blob, e.state = nil, "saved"
        Outbox.forgetIfDone(sid)
        GBA.Print(string.format("session %s is safe with %s; your copy is deleted", sid, from))
    end,
    onFailed = function(sid, why)
        local e = mine()[sid]
        if not e then return end
        -- A copy offered again to a reader, after its courier went: nobody taking it leaves it
        -- delivered, as it was.
        if e.reoffered then e.reoffered = nil; return end
        e.state, e.lastError = "pending", why
    end,
})
for _, kind in ipairs({ "ACC", "NEED", "GOT", "BAD", "HOLD" }) do
    Net.on(kind, function(from, text) sender:handle(from, text) end)
end
Net.every(function() sender:pump() end)

-- Offers every waiting session to the online officers, and asks which delivered ones they
-- now hold on disk. Returns how many officers were online.
function Outbox.flush()
    local officers = GBA.onlineOfficers()
    if #officers == 0 then return 0 end
    local online = {}
    for _, name in ipairs(officers) do online[GBA.Net.short(name)] = true end
    local delivered = {}
    for sid, e in pairs(mine()) do
        if e.state == "pending" then
            local blob = Crypto.fromHex(e.blob)
            if blob and sender:offer(sid, blob, officers) then e.state = "offered" end
        elseif e.state == "delivered" and e.blob and e.courier and not online[GBA.Net.short(e.courier)] then
            -- The courier has gone, and the session may not have reached its readers yet. This
            -- copy is offered to the readers online: an offer is a small question, and a reader
            -- that already holds it simply does not take it (seen in the soak, seed 5).
            local readers = {}
            for _, name in ipairs(e.readers or {}) do
                if online[GBA.Net.short(name)] then readers[#readers + 1] = name end
            end
            local blob = #readers > 0 and Crypto.fromHex(e.blob)
            if blob and sender:offer(sid, blob, readers) then e.reoffered = true end
        end
        -- Asked about pending ones too: an officer may already hold a session whose GOT
        -- never arrived, and one that holds it refuses a second copy, so only HOLD can
        -- settle it. A delivered one is asked of its courier, who saves it, or, with the
        -- courier gone, of its readers online; not of every officer.
        if e.blob and (e.state == "pending" or e.state == "offered") then
            for _, name in ipairs(officers) do
                delivered[name] = delivered[name] or {}
                table.insert(delivered[name], sid)
            end
        elseif e.blob and e.state == "delivered" then
            local targets = {}
            if e.courier and online[GBA.Net.short(e.courier)] then
                targets[1] = GBA.Net.short(e.courier)
            else
                for _, name in ipairs(e.readers or {}) do
                    if online[GBA.Net.short(name)] then targets[#targets + 1] = GBA.Net.short(name) end
                end
            end
            for _, name in ipairs(targets) do
                delivered[name] = delivered[name] or {}
                table.insert(delivered[name], sid)
            end
        end
    end
    for name, sids in pairs(delivered) do sender:askHolding(sids, { name }) end
    return #officers
end

-- Locks a session. `readers` are the officers the reward names. done(sid) runs once every
-- letter is locked. Returns the sid, or nil and a reason.
--
-- With `hold`, the locked session stays on this computer until Outbox.release: the claim
-- flow locks it when Claim is pressed, but nothing leaves until the player presses Send on
-- the mail. A claim abandoned before then is cancelled and never leaves at all.
function Outbox.submit(payload, readers, done, hold)
    if type(readers) ~= "table" or #readers == 0 then return nil, "a session needs at least one reader" end
    local sid = Crypto.toHex(Net.random(4))
    local sessionKey = Net.random(32)
    local blob = Crypto.sealRaw(sessionKey, Codec.pack(payload), Net.random(Crypto.NONCE_BYTES))
    if #blob > Transfer.MAX_SIZE then return nil, "this session is too large to send" end

    local entry = { blob = Crypto.toHex(blob), created = time(), state = "locking", readers = readers,
        letters = {}, lettersSent = {} }
    mine()[sid] = entry

    local waiting = #readers
    local function oneDone()
        waiting = waiting - 1
        if waiting > 0 then return end
        -- Every letter is locked: the session key is dropped here and never saved.
        sessionKey = nil
        if hold then
            entry.state = "held"
        else
            entry.state = "pending"
            Outbox.flush()
        end
        if done then done(sid) end
    end
    for _, reader in ipairs(readers) do
        local pub = directory:get(reader)
        if pub then
            Keys.lock(sessionKey, sid, pub, Net.random, Net.keyOp, function(block)
                entry.letters[reader] = block
                oneDone()
            end)
        else
            -- No key for this reader: they can never open this session. Said out loud.
            entry.letters[reader] = false
            GBA.Print("|cffff4040no key for " .. reader .. " yet:|r they will not be able to open session " .. sid)
            oneDone()
        end
    end
    return sid
end

-- The player pressed Send: the held session may now go to the officers.
function Outbox.release(sid)
    local e = mine()[sid]
    if not e or e.state ~= "held" then return false end
    e.state = "pending"
    Outbox.flush()
    return true
end

-- The claim was abandoned before Send: the locked session is deleted and never leaves.
function Outbox.cancel(sid)
    local e = mine()[sid]
    if e and e.state == "held" then mine()[sid] = nil; return true end
    return false
end

-- An entry is forgotten once its data is safe with an officer and every letter is mailed.
function Outbox.forgetIfDone(sid)
    local e = mine()[sid]
    if not e or e.blob then return end
    for _, reader in ipairs(e.readers or {}) do
        if e.letters[reader] and not (e.lettersSent and e.lettersSent[reader]) then return end
    end
    mine()[sid] = nil
end

function Outbox.markLetterSent(sid, reader)
    local e = mine()[sid]
    if not e then return end
    e.lettersSent = e.lettersSent or {}
    e.lettersSent[reader] = true
    Outbox.forgetIfDone(sid)
end

-- Letters still to be mailed, across every released session: resumed at the next mailbox.
function Outbox.unsentLetters()
    local out = {}
    for sid, e in pairs(mine()) do
        if e.state ~= "held" and e.state ~= "locking" then
            for _, l in ipairs(Outbox.letters(sid)) do
                if not (e.lettersSent and e.lettersSent[l.to]) then
                    out[#out + 1] = { sid = sid, to = l.to, body = l.body }
                end
            end
        end
    end
    return out
end

-- The letters for one session, as mail bodies, for the claim flow to post.
function Outbox.letters(sid)
    local e = mine()[sid]
    local out = {}
    if not e then return out end
    for _, reader in ipairs(e.readers or {}) do
        local block = e.letters[reader]
        if block then
            out[#out + 1] = { to = reader, block = block,
                body = Keys.letterBody(sid, UnitName("player"), reader, block) }
        end
    end
    return out
end

-- Sync moments ------------------------------------------------------------------------------

local lastSync = -math.huge
local keysAsked = false

local function hasWork()
    return next(mine()) ~= nil
end

function Outbox.sync(force)
    local t = Net.now()
    if not force and t - lastSync < Outbox.SYNC_INTERVAL then return end
    if not force and not hasWork() and keysAsked then return end
    lastSync = t
    if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster)
    elseif GuildRoster then pcall(GuildRoster) end
    -- The roster answers a moment later.
    C_Timer.After(2, function()
        if not keysAsked then keysAsked = true; Outbox.requestKeys() end
        Outbox.flush()
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:SetScript("OnEvent", function(_, event)
    -- Login and reload both arrive as PLAYER_ENTERING_WORLD; give the guild roster time.
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(8, function() Outbox.sync(true) end)
    else
        Outbox.sync(false)
    end
end)

-- Dev -------------------------------------------------------------------------------------

