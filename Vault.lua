-- The officer's vault: this officer's keys, and the locked sessions they carry.
--
-- Spec: docs/superpowers/specs/2026-09-23-secure-transport-design.md.
--
-- Identity. This account's officer key pair is made once. The private half is saved here and
-- never leaves this computer: not in a message, a log or an export. The public half is
-- announced on the officer channel and handed to any client that asks.
--
-- Holding. Any officer may carry a session and keep it, readable or not. A session is held
-- exactly as it arrived: locked with a session key this officer may never see.
--
-- Unlocking. A key letter in this officer's mailbox, opened with the private key, gives the
-- session key. The session key is then kept with the session, so an unlocked session stays
-- readable even if the private key is later lost. Sessions held but never unlocked cannot be
-- opened by anyone else, ever.
--
-- Crash tolerance. A session only counts as held once it has come back from disk after a
-- login or reload. Until then it is not listed in HOLD, so the client keeps its copy.
--
-- Syncing between officers. An officer who has a key letter but not its session asks the
-- online officers for it (WANT), and one that holds it sends it over the same transfer
-- protocol a client uses: still locked, and only ever to an officer. Asked again at every
-- sync moment until it arrives.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Crypto, Keys, Transfer, Codec, Net = GBA.Crypto, GBA.Keys, GBA.Transfer, GBA.Codec, GBA.Net

local Vault = {}
ns.Vault = Vault

-- Who holds an encryption key and reads what is shared with them: officers, who also carry
-- sessions for others; publishers, since a data offer's poster is its first reader; and readers.
-- Only the officer role used to, so a reader named on an offer could never read, and a publisher
-- without the officer role posted data offers nobody could claim (docs/fix-plan.md, D3).
-- Roles and keys otherwise never mix (secure-transport spec, access control). Carrying stays an
-- officer's job. With a name, asks about that character; without, about this one.
local function readsData(name, rank)
    if name then
        local facts = { name = name, rankIndex = rank }
        return GBA.Authority.may("officer", facts) or GBA.Authority.may("offer", facts)
            or GBA.Authority.may("reader", facts)
    end
    return GBA.mayAct("officer") or GBA.mayAct("offer") or GBA.mayAct("reader")
end

local identity = nil          -- { private = hex, public = hex, onDisk = came back from saved data }
local held = {}               -- sid -> { from, blob = hex, at, sessionKey = hex?, unlockedAt?, fromDisk? }
local waitingKeys = {}        -- sid -> session key hex, for a letter whose session has not arrived
local directory = Keys.newDirectory()

ns.persist("identity", function()
    return identity and { private = identity.private, public = identity.public,
        signSeed = identity.signSeed, signPublic = identity.signPublic } or nil
end, function(saved)
    if type(saved) == "table" and type(saved.private) == "string" and Keys.validPublic(saved.public) then
        -- Back from disk: safe to share. A key made this session is not until a logout or reload.
        identity = { private = saved.private, public = saved.public, onDisk = true }
        -- The signature key (Ed25519) beside the transport key. Kept only if both halves are
        -- well formed; otherwise a fresh one is made at the next login.
        if type(saved.signSeed) == "string" and #saved.signSeed == 64 and not saved.signSeed:find("[^%x]")
            and type(saved.signPublic) == "string" and #saved.signPublic == 64 then
            identity.signSeed, identity.signPublic = saved.signSeed, saved.signPublic
        end
    end
end)

ns.persist("held", function()
    local out = {}
    for sid, h in pairs(held) do
        out[sid] = { from = h.from, blob = h.blob, at = h.at, sessionKey = h.sessionKey, unlockedAt = h.unlockedAt,
            sessionID = h.sessionID }
    end
    return out
end, function(saved)
    if type(saved) ~= "table" then return end
    for sid, h in pairs(saved) do
        if type(sid) == "string" and type(h) == "table" and type(h.blob) == "string" then
            h.fromDisk = true       -- back from disk: now it may be listed in HOLD
            held[sid] = h
        end
    end
end)

ns.persist("waitingKeys", function() return waitingKeys end,
    function(saved) if type(saved) == "table" then waitingKeys = saved end end)

-- Who each session's key letter came from, as the mail server names the sender: the player who
-- claimed. The one name about a session nobody can write for themselves. The data inside names
-- its own player, and whoever carried it here may be another officer, so analytics credits the
-- session to this name and counts nothing that says otherwise (docs/fix-plan.md, I9, S2).
local claimants = {}          -- sid -> character name
ns.persist("claimants", function() return claimants end,
    function(saved) if type(saved) == "table" then claimants = saved end end)

ns.persist("directory", function() return directory:export() end,
    function(saved) directory = Keys.newDirectory(saved) end)

-- Keys ------------------------------------------------------------------------------------

-- The officer's signature key: what they sign offers (and, next, claim decisions) with. Made
-- beside the transport key, from the same entropy pool. It counts only once the guild master
-- has stamped it into the role list.
-- Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md.
local makingSigner = false
local announceSigner

-- Made as a job (GBA.edJob): worked out whole, it is enough for the game to stop the addon.
local function ensureSigner()
    if not identity or identity.signSeed or makingSigner then return end
    makingSigner = true
    local seed = Net.random(32)
    GBA.edJob(function() return Crypto.toHex(GBA.Ed25519.publicKey(seed)) end, function(public)
        makingSigner = false
        identity.signSeed, identity.signPublic = Crypto.toHex(seed), public
        GBA.Print("made this account's signature key; the guild master stamps it into the role list")
        announceSigner()
    end)
end

local lastSigAnnounce = -math.huge
local sigDeferred = false

-- Said on officer chat and also whispered to each officer online and the guild master. A role
-- holder whose rank cannot speak on officer chat was never heard there, so never stamped and
-- never learned: rank still decided roles through a side door (docs/fix-plan.md, I3, R-2).
-- Whisper always works; hearing it twice changes nothing.
local function tellOfficers(text)
    Net.officers(text)
    local told, me = {}, UnitName("player")
    for _, name in ipairs(GBA.onlineOfficers()) do
        name = GBA.Net.short(name)
        if name ~= me and not told[name] then told[name] = true; Net.whisper(name, text) end
    end
    for i = 1, (GetNumGuildMembers and GetNumGuildMembers() or 0) do
        local fullName, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
        local name = fullName and GBA.Net.short(fullName)
        if rankIndex == 0 and online and name and name ~= me and not told[name] then
            Net.whisper(name, text)
        end
    end
end

-- At most once every 30 seconds. One asked for sooner is sent when the 30 seconds are up, not
-- dropped: the guild master can only stamp a key once a role list exists, so the announcement
-- that matters is the one after the first list arrives, which is often seconds after login's.
-- Dropping it left keys unstamped for good (found by the soak, seed 1).
announceSigner = function()
    if not identity or not identity.signPublic or not (GBA.mayAct("officer") or GBA.mayAct("offer")) then return end
    local t = Net.now()
    local wait = 30 - (t - lastSigAnnounce)
    if wait > 0 then
        if not sigDeferred then
            sigDeferred = true
            C_Timer.After(wait, function() sigDeferred = false; announceSigner() end)
        end
        return
    end
    lastSigAnnounce = t
    tellOfficers("SIG:" .. identity.signPublic)
end

-- A new officer key is shared only once it is on disk. WoW writes saved data only at a logout or
-- a /reload, so a key shared the moment it was made could be lost to a crash, and with it every
-- session members had locked to it: they could never be opened (found by the soak, seed 11). The
-- officer is asked, once a session, to /reload; the key goes out when it comes back from disk.
-- The signature key is not held back: one lost that way is simply stamped again.
-- Adding an entry is safe; assigning StaticPopupDialogs itself is not. That line (even writing the
-- same table back) tainted the global every popup reads, and the logout popup's Cancel was then
-- blocked calling the protected CancelLogout, blamed on this addon (BugSack, 2026-09-25).
StaticPopupDialogs["GUILDLEDGER_SAVE_KEYS"] = {
    text = "GuildLedger made this account's officer keys.\n\n/reload once now so they are saved. Until then "
        .. "they are not shared, because a crash would lose them, and any claims locked to them.",
    button1 = "Reload now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
local askedToSave = false

local function askToSave()
    if askedToSave then return end
    askedToSave = true
    GBA.Print("|cffffcc00your officer keys are new: /reload once so they are saved. They are shared after that.|r")
    if StaticPopup_Show then StaticPopup_Show("GUILDLEDGER_SAVE_KEYS") end
end

local function announce()
    -- The key is account-wide, but only an officer character speaks for it. A member alt on
    -- the same account with this addon enabled once announced the officer's key under the
    -- alt's own name.
    if not identity or not readsData() then return end
    ensureSigner()
    announceSigner()
    if not identity.onDisk then return askToSave() end
    directory:learn(UnitName("player"), identity.public, UnitName("player"))
    tellOfficers("PUB:" .. identity.public)
end

function Vault.ensureIdentity()
    if identity or not readsData() then return end
    Keys.newIdentity(Net.random, Net.keyOp, function(id)
        identity = id
        GBA.Print("made this account's officer key; announcing it to the other officers")
        announce()
    end)
end

-- The signature key, for signing: seed and public key as raw bytes, or nil if there is none.
function Vault.signer()
    if not identity or not identity.signSeed then return nil end
    return Crypto.fromHex(identity.signSeed), Crypto.fromHex(identity.signPublic)
end

function Vault.signPublic()
    return identity and identity.signPublic or nil
end

-- A list in force without this officer's key stamped: say it again, so the guild master's
-- client hears it (it stamps only what it hears straight from us).
GBA.onRoleList(function()
    if identity and identity.signPublic and GBA.roles:keyOf(UnitName("player")) ~= identity.signPublic then
        announceSigner()
    end
end)

Net.on("PUB", function(from, text)
    local pub = text:match("^PUB:(%x+)$")
    -- Heard by whisper too now (tellOfficers), so the sender is checked: only an officer's key
    -- belongs in the officer directory.
    if not readsData(GBA.Net.short(from), GBA.rosterRankOf(from)) then return end
    if pub then directory:learn(from, pub, from) end
end)

-- A client asking for officer keys gets every one this officer knows, its own included.
Net.on("KEYREQ", function(from)
    if not GBA.mayAct("officer") then return end
    for _, name in ipairs(directory:names()) do
        Net.whisper(from, "KEY:" .. name .. ":" .. directory:get(name))
    end
end)

-- Syncing between officers --------------------------------------------------------------

-- Sends held sessions to officers who ask. The copy here is kept: officers hold what they carry.
local sender = Transfer.newSender({
    send = Net.whisper, now = Net.now, random = Net.random, keyOp = Net.keyOp,
    onDelivered = function(sid, to) GBA.Print("sent the locked session " .. sid .. " to " .. to) end,
})
for _, kind in ipairs({ "ACC", "NEED", "GOT", "BAD" }) do
    Net.on(kind, function(from, text) sender:handle(from, text) end)
end
Net.every(function() sender:pump() end)

Net.on("WANT", function(from, text)
    local sid = text:match("^WANT:(%x+)$")
    local h = sid and held[sid]
    if not h or not GBA.mayAct("officer") then return end
    -- Locked or not, a session goes only to someone with a data role (an officer, a publisher,
    -- a reader): clients never hold others' data. Only its named readers hold its key.
    if not readsData(GBA.Net.short(from), GBA.rosterRankOf(from)) then return end
    local blob = Crypto.fromHex(h.blob)
    if blob then sender:offer(sid, blob, { from }) end
end)

-- Asks the online officers for every session this officer has a key for but not the data: one
-- officer at a time, not all at once. If no transfer has begun within FETCH_WAIT seconds (they
-- do not hold it, or the ask was lost), the next is asked, until each has been.
local FETCH_WAIT = 15
local receiver         -- the transfer receiver, made below; checked for a transfer under way
local fetching = {}      -- sid -> true while a chain of asks is running

function Vault.fetchMissing()
    local me, officers = UnitName("player"), {}
    for _, name in ipairs(GBA.onlineOfficers()) do
        name = GBA.Net.short(name)
        if name ~= me then officers[#officers + 1] = name end
    end
    if #officers == 0 then return 0 end
    table.sort(officers)
    local asked = 0
    for sid in pairs(waitingKeys) do
        if not held[sid] and not fetching[sid] then
            asked = asked + 1
            fetching[sid] = true
            local i = 0
            local function askNext()
                i = i + 1
                if held[sid] or not waitingKeys[sid] or not officers[i] then fetching[sid] = nil; return end
                Net.whisper(officers[i], "WANT:" .. sid)
                C_Timer.After(FETCH_WAIT, function()
                    if receiver and receiver.inbound and receiver.inbound[sid] then
                        -- A transfer is under way: wait for it rather than asking someone else.
                        return C_Timer.After(FETCH_WAIT, askNext)
                    end
                    askNext()
                end)
            end
            askNext()
        end
    end
    return asked
end

-- Unlocking ---------------------------------------------------------------------------------

-- Opened over several frames: a long session opened whole was stopped by the game with "script
-- ran too long" (2026-09-27, bot sessions of 13 KB). The decrypting runs a few blocks a frame,
-- then reading and ingesting get a frame of their own. done(ok), when given, says how it went.
local opening = {}

local function open(sid, done)
    local h = held[sid]
    local function finish(ok) if done then done(ok) end end
    if not h or not h.sessionKey or h.unlockedAt or opening[sid] then return finish(h and h.unlockedAt ~= nil) end
    local blob = Crypto.fromHex(h.blob)
    if not blob then
        GBA.Print("|cffff4040session " .. sid .. " is damaged on disk|r")
        return finish(false)
    end
    opening[sid] = true
    Crypto.openRawAsync(Crypto.fromHex(h.sessionKey), blob, function(packed)
        if not packed then
            opening[sid] = nil
            GBA.Print("|cffff4040session " .. sid .. " did not open with its key|r")
            return finish(false)
        end
        C_Timer.After(0, function()
            opening[sid] = nil
            local payload, why = Codec.unpack(packed)
            if not payload then
                GBA.Print("|cffff4040session " .. sid .. " opened but could not be read:|r " .. tostring(why))
                return finish(false)
            end
            -- Field layouts belong to the schema version; reading rows under the wrong one assigns
            -- the wrong meaning to every value, so a mismatch is refused, never guessed at.
            if payload.schemaVersion ~= GBA.Schema.VERSION then
                GBA.Print(string.format("|cffffcc00session %s is schema v%s, this client reads v%d|r",
                    sid, tostring(payload.schemaVersion), GBA.Schema.VERSION))
                return finish(false)
            end
            h.unlockedAt = time()
            GBA.Print(string.format("|cff40ff40unlocked session %s from %s|r", sid, tostring(h.from)))
            if ns.acceptClaim then
                -- The claimant: whoever mailed the key letter, else the claim this officer holds
                -- for the session. Both are names the server gave, not the data.
                local claimant = claimants[sid]
                if not claimant and ns.officerClaims then
                    for _, r in ipairs(ns.officerClaims:all()) do
                        if r.transferID == sid then claimant = r.from break end
                    end
                end
                ns.acceptClaim({ facts = payload.facts, sessions = payload.sessions, from = h.from, claimant = claimant })
            end
            finish(true)
        end)
    end)
end

-- Data joins the guild's analytics once its claim is accepted, not when its key letter is read
-- (docs/fix-plan.md, D10, N2; Guild.lua: "the gate belongs in FRONT of ingest"). A declined
-- claim's session was counted all the same.
--
-- The claim's state, for the session it sent: "settled", "declined", "open", or nil when this
-- officer knows no claim for it: one it decides, or one it holds for another poster together
-- with any decision it has seen on it.
local STATE_WORD = { [GBA.Reward.state.settled] = "settled", [GBA.Reward.state.declined] = "declined" }

local function claimStateFor(sid)
    local claims = ns.officerClaims
    if not claims then return nil end
    for _, r in ipairs(claims:all()) do
        if r.transferID == sid then return STATE_WORD[r.state] or "open" end
    end
    for _, h in pairs(claims.relays or {}) do
        if type(h.claim) == "table" and h.claim.transferID == sid then
            local key = tostring(h.from) .. "|" .. tostring(h.claim.rewardID) .. "|state|" .. tostring(h.claim.at)
            local n = (claims.log or {})[key] or (claims.carried or {})[key]
            return n and STATE_WORD[n.state] or "open"
        end
    end
    return nil
end

-- Opens a session whose key is here, when that is allowed: its claim awarded, or no claim known
-- here to wait on (a reader who is not an officer never holds claims, and would never read). A
-- declined claim's session stays locked; an open claim's waits for the award.
local waitSaid = {}
local function openWhenAccepted(sid)
    local state = claimStateFor(sid)
    if state == "declined" then return end
    if state == "open" then
        if not waitSaid[sid] then
            waitSaid[sid] = true
            GBA.Print("key for session " .. sid .. " kept; the session opens once its claim is awarded")
        end
        return
    end
    open(sid)
end

-- Opens every session held here with its key whose claim has been awarded since. Run after any
-- decision this client makes or hears of, and at login.
function Vault.openAccepted()
    for sid, h in pairs(held) do
        if h.sessionKey and not h.unlockedAt then openWhenAccepted(sid) end
    end
end

-- Read-only views for the Vault tab. The public key only: the private half never leaves here.
function Vault.identity()
    return identity and { public = identity.public } or nil
end

function Vault.overview()
    local list, waiting = {}, {}
    for sid, h in pairs(held) do
        list[#list + 1] = { sid = sid, from = h.from, unlockedAt = h.unlockedAt, fromDisk = h.fromDisk, at = h.at }
    end
    table.sort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)
    for sid in pairs(waitingKeys) do
        if not held[sid] then waiting[#waiting + 1] = sid end
    end
    table.sort(waiting)
    return list, waiting
end

function Vault.status(sid)
    local h = held[sid]
    if h and h.unlockedAt then return "unlocked" end
    if h and h.sessionKey then return "key here; opens once its claim is awarded" end
    if h then return "held, locked; waiting for this officer's key letter" end
    if waitingKeys[sid] then return "key letter opened; the session has not arrived yet" end
    return "not arrived yet"
end

-- Opens the key letters in this officer's mailbox. Letters are never deleted by the addon, so
-- this can always be run again. With `wanted(index)`, only the mails it picks are read: reading
-- a mail's body marks it read, so the automatic pass reads only mail that can hold a key.
local function unlockLetters(wanted, quiet)
    local found = 0
    for i = 1, (GetInboxNumItems and GetInboxNumItems() or 0) do
        local text = (not wanted or wanted(i)) and GetInboxText and GetInboxText(i) or nil
        local _, _, sender = GetInboxHeaderInfo(i)
        for _, block in ipairs(Keys.findLetters(text)) do
            found = found + 1
            Keys.unlock(block, identity.private, Net.keyOp, function(sid, key, why)
                if not key then
                    if quiet then return end
                    return GBA.Print("|cffffcc00a key letter for session " .. tostring(sid) .. " is not for this key:|r " .. tostring(why))
                end
                if type(sender) == "string" and sender ~= "" then claimants[sid] = GBA.Net.short(sender) end
                -- Already opened, here or on an earlier pass: nothing to do.
                if (held[sid] and held[sid].unlockedAt) or waitingKeys[sid] then return end
                local hex = Crypto.toHex(key)
                if held[sid] then
                    held[sid].sessionKey = hex
                    openWhenAccepted(sid)
                else
                    waitingKeys[sid] = hex
                    GBA.Print("key for session " .. sid .. " kept; the session itself has not reached this officer yet")
                    Vault.fetchMissing()
                end
            end)
        end
    end
    return found
end

-- The Vault panel's button: every letter in the mailbox.
function Vault.unlockFromMail()
    if not identity then return GBA.Print("this account has no officer key yet") end
    if not (MailFrame and MailFrame:IsShown()) then return GBA.Print("open the mailbox first") end
    if unlockLetters() == 0 then
        GBA.Print("no key letters in this mailbox (click a letter open if it has not loaded)")
    end
end

-- Opened by itself when the mailbox opens, and once more when the inbox has loaded
-- (docs/fix-plan.md, DEC-16, D2): an unread letter the game deletes after 30 days is a session
-- nobody can ever read. Only mail that can hold a key is read, since reading marks it read: a
-- letter titled "Session key ...", or mail from a player whose session is here waiting for its
-- key (the poster's letter rides in the claim mail itself).
local function waitingFrom()
    local out = {}
    for _, h in pairs(held) do
        if not h.unlockedAt and not h.sessionKey and h.from then out[GBA.Net.short(h.from)] = true end
    end
    for _, r in ipairs(ns.officerClaims and ns.officerClaims:all() or {}) do
        if r.transferID and not (held[r.transferID] and held[r.transferID].unlockedAt) then out[r.from] = true end
    end
    return out
end

local function autoUnlock()
    if not identity or not readsData() then return end
    local from = waitingFrom()
    unlockLetters(function(i)
        local _, _, sender, subject = GetInboxHeaderInfo(i)
        if type(subject) == "string" and subject:find("^Session key ") then return true end
        return type(sender) == "string" and from[GBA.Net.short(sender)] == true
    end, true)
end

local passed = false
GBA.Mailbox.onOpen(function() passed = false; C_Timer.After(1, autoUnlock) end)
local inbox = CreateFrame("Frame")
inbox:RegisterEvent("MAIL_INBOX_UPDATE")
inbox:SetScript("OnEvent", function()
    if passed or not GBA.Mailbox.isOpen() then return end
    passed = true
    autoUnlock()
end)

-- Receiving ---------------------------------------------------------------------------------

-- Officers share what they carry (secure-transport spec, part 5): a session that has just
-- arrived here is offered on to the other officers online, and whoever takes it does the same,
-- so it ends up on every officer online instead of only its first carrier. The player deletes
-- their copy once one officer has it on disk, so a session that stayed with that one officer
-- was gone if they quit before its reader met them (docs/fix-plan.md, I6). No loop: an officer
-- that holds a session turns the offer down, and one send per session runs at a time. Only an
-- officer carries; a reader who fetched a session keeps it.
function Vault.share(sid, except)
    local h = held[sid]
    if not h or not GBA.mayAct("officer") then return false end
    local blob = Crypto.fromHex(h.blob)
    if not blob then return false end
    local me, skip, to = UnitName("player"), GBA.Net.short(except or ""), {}
    for _, name in ipairs(GBA.onlineOfficers()) do
        name = GBA.Net.short(name)
        if name ~= me and name ~= skip then to[#to + 1] = name end
    end
    if #to == 0 then return false end
    return sender:offer(sid, blob, to) == true
end

receiver = Transfer.newReceiver({
    send = Net.whisper, now = Net.now, random = Net.random, keyOp = Net.keyOp,
    accept = function(from, sid)
        if GBA.rosterEntry(from) == nil then return false end
        -- An officer carries anything offered; anyone else with a data role takes only a session
        -- they asked for, one they are named to read (D3).
        if not (GBA.mayAct("officer") or (fetching[sid] and readsData())) then return false end
        -- Already carried: nothing to gain from a second copy.
        return not held[sid]
    end,
    onReceived = function(sid, from, blob)
        if not held[sid] then
            held[sid] = { from = from, blob = Crypto.toHex(blob), at = time() }
            GBA.Print(string.format("holding session %s from %s: locked, %d bytes", sid, from, #blob))
            -- On to the other officers online, a moment later, once this transfer has settled.
            C_Timer.After(3, function() Vault.share(sid, from) end)
        end
        if waitingKeys[sid] then
            held[sid].sessionKey = waitingKeys[sid]
            waitingKeys[sid] = nil
            openWhenAccepted(sid)
        end
    end,
    holdingOnDisk = function(from, sids)
        local out = {}
        for _, sid in ipairs(sids) do
            local h = held[sid]
            if h and h.fromDisk and h.from == from then out[#out + 1] = sid end
        end
        return out
    end,
})
for _, kind in ipairs({ "REQ", "P", "END", "ASKHOLD" }) do
    Net.on(kind, function(from, text) receiver:handle(from, text) end)
end

local lastSweep = 0
Net.every(function()
    local t = Net.now()
    if t - lastSweep > 10 then lastSweep = t; receiver:sweep() end
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
    -- The roster has to arrive before the officer role can be checked.
    C_Timer.After(6, function()
        if identity then announce() else Vault.ensureIdentity() end
        Vault.fetchMissing()
        -- Claims awarded while this officer was away: their sessions open now.
        Vault.openAccepted()
    end)
end)

