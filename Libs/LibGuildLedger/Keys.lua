-- Officer keys, the client's key directory, and key letters. Pure: no WoW API.
--
-- Spec: docs/superpowers/specs/2026-09-23-secure-transport-design.md, "The three keys" and
-- "Before anything: every client holds every officer's public key".
--
-- Identity keys. Each officer makes an X25519 key pair once. The private half never leaves
-- their computer: not in a payload, a log or an export. The public half is shared with
-- every client.
--
-- The directory. Every client keeps every officer's public key. Public keys are public, and
-- a fake one in the directory cannot leak a session: the letter it locks is mailed to the
-- named officer, and the server delivers that mail to nobody else. The worst a fake key does
-- is leave that officer unable to open one session. Even so, a key an officer sends about
-- THEMSELVES always beats a copy relayed by someone else, so a relayed fake can never
-- displace the real key, and an officer who reinstalls replaces their own.
--
-- Key letters. A session key, locked so only one officer can open it: a one-time key pair,
-- combined with that officer's public key, gives a secret only their private key can
-- recreate. The letter is text for a mail body.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto, X25519
if ns then
    Crypto, X25519 = ns.Crypto, ns.X25519
else
    Crypto, X25519 = require("Crypto"), require("X25519")
end

local Keys = {}

Keys.LETTER_TAG = "GBAKEY1"

-- Identity -----------------------------------------------------------------------------

-- Makes a key pair. random(n) comes from the entropy pool; keyOp may finish later.
-- done({ private = hex, public = hex })
function Keys.newIdentity(random, keyOp, done)
    local private = random(32)
    keyOp(private, X25519.BASE, function(public)
        done({ private = Crypto.toHex(private), public = Crypto.toHex(public) })
    end)
end

function Keys.validPublic(hex)
    return type(hex) == "string" and #hex == 64 and not hex:find("[^%x]")
end

-- Directory -----------------------------------------------------------------------------

local Directory = {}
Directory.__index = Directory
Keys.Directory = Directory

-- saved: what export() returned last time, or nil.
function Keys.newDirectory(saved)
    local d = setmetatable({ entries = {} }, Directory)
    if type(saved) == "table" then
        for name, e in pairs(saved) do
            if type(name) == "string" and type(e) == "table" and Keys.validPublic(e.public) then
                d.entries[name] = { public = e.public, direct = e.direct and true or false }
            end
        end
    end
    return d
end

-- `from` is the server-attested sender of the message carrying the key. Returns true when the
-- directory changed.
function Directory:learn(name, public, from)
    if type(name) ~= "string" or not Keys.validPublic(public) then return false end
    local direct = (from == name)
    local current = self.entries[name]
    if current then
        if current.public == public then
            if direct and not current.direct then current.direct = true; return true end
            return false
        end
        -- A relayed copy never displaces a key the officer sent about themselves.
        if current.direct and not direct then return false end
    end
    self.entries[name] = { public = public, direct = direct }
    return true
end

function Directory:get(name)
    local e = self.entries[name]
    return e and e.public or nil
end

function Directory:names()
    local list = {}
    for name in pairs(self.entries) do list[#list + 1] = name end
    table.sort(list)
    return list
end

function Directory:export()
    local out = {}
    for name, e in pairs(self.entries) do out[name] = { public = e.public, direct = e.direct } end
    return out
end

-- Key letters ---------------------------------------------------------------------------

local function wrapKey(shared, sid)
    return Crypto.hmac(shared, "wrap|" .. sid)
end

-- Locks `sessionKey` for the officer whose public key is `officerPublicHex`.
-- done(block) where block is "GBAKEY1:sid:oneTimePublicHex:E1:..."
function Keys.lock(sessionKey, sid, officerPublicHex, random, keyOp, done)
    assert(Keys.validPublic(officerPublicHex), "not an officer public key")
    local oneTime = random(32)
    keyOp(oneTime, X25519.BASE, function(oneTimePublic)
        keyOp(oneTime, Crypto.fromHex(officerPublicHex), function(shared)
            local locked = Crypto.seal(wrapKey(shared, sid), sessionKey, random(Crypto.NONCE_BYTES))
            done(Keys.LETTER_TAG .. ":" .. sid .. ":" .. Crypto.toHex(oneTimePublic) .. ":" .. locked)
        end)
    end)
end

-- Every key block in a piece of text, such as a mail body.
function Keys.findLetters(text)
    local found = {}
    if type(text) ~= "string" then return found end
    for block in text:gmatch(Keys.LETTER_TAG .. ":%x+:%x+:E1:[%x:]+") do
        found[#found + 1] = block
    end
    return found
end

function Keys.parse(block)
    if type(block) ~= "string" then return nil end
    local sid, oneTimeHex, locked = block:match("^" .. Keys.LETTER_TAG .. ":(%x+):(%x+):(E1:[%x:]+)$")
    if not sid or #oneTimeHex ~= 64 then return nil end
    return { sid = sid, oneTimePublic = oneTimeHex, locked = locked }
end

-- Opens a letter with this officer's private key.
-- done(sid, sessionKey) or done(sid, nil, reason). A letter locked for someone else, or
-- damaged, is refused, never guessed at.
function Keys.unlock(block, privateHex, keyOp, done)
    local letter = Keys.parse(block)
    if not letter then return done(nil, nil, "not a key letter") end
    local private = Crypto.fromHex(privateHex or "")
    if not private or #private ~= 32 then return done(letter.sid, nil, "no private key") end
    keyOp(private, Crypto.fromHex(letter.oneTimePublic), function(shared)
        local sessionKey, why = Crypto.open(wrapKey(shared, letter.sid), letter.locked)
        if not sessionKey then return done(letter.sid, nil, why or "not locked for this key") end
        done(letter.sid, sessionKey)
    end)
end

-- The mail body around a key letter: short, deliberate, and readable by the person who opens
-- it, because showing the security is part of the point.
function Keys.letterBody(sid, sender, officer, block)
    return "Session key for session " .. sid .. " from " .. tostring(sender)
        .. ". Only " .. tostring(officer) .. " can open it.\n\n" .. block
end

if ns then ns.Keys = Keys end
return Keys
