-- The guild master's signed role list. Pure: no WoW API.
--
-- Spec: docs/superpowers/specs/2026-09-23-secure-transport-design.md, "Access control: the
-- guild master role key".
--
-- Roles decide who may publish a reward, who may be named as a reader, who may carry data,
-- and who may use the dev tools. Keys decide who can open a session. The two never mix: a
-- role grants no reading, and the role key unlocks nothing.
--
--   Pinning. A client trusts a guild master key only when it arrives in a message the SERVER
--   stamps as sent by the rank-0 character, the guild master. The stamp introduces the key
--   once; after that the key vouches for every list, whoever carries it.
--   Accepting. A list is taken only if its signature verifies against the pinned key and its
--   number is higher than the list already held, so an old list can never come back.
--   A new guild master. The roster shows someone else at rank 0: their key is pinned the same
--   way and their lists win from then on.
--   No list yet. Rank decides, as before (Authority's fallback).
--
-- Accepted risk, in the user's words: "if the guild master is silly enough to give away his
-- key, he's giving away his kingdom."
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto, Ed25519
if ns then
    Crypto, Ed25519 = ns.Crypto, ns.Ed25519
else
    Crypto, Ed25519 = require("Crypto"), require("Ed25519")
end

local Roles = {}

Roles.KINDS = { "publisher", "reader", "officer", "dev" }
-- GBAROLES2 adds the keys section: each officer's signature public key, stamped by the guild
-- master. Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md.
Roles.TAG = "GBAROLES2"
Roles.MAX_NAMES = 40

local function validKey(hex)
    return type(hex) == "string" and #hex == 64 and not hex:find("[^%x]")
end

local validKind = {}
for _, k in ipairs(Roles.KINDS) do validKind[k] = true end

local function cleanName(name)
    if type(name) ~= "string" then return nil end
    name = name:match("^([^%-]+)") or name
    if #name == 0 or #name > 24 or name:find("[%s%p%c]") then return nil end
    return name
end

-- A normalised list: every role a sorted set of names, and a number.
function Roles.newList(fields)
    fields = type(fields) == "table" and fields or {}
    local list = { n = math.floor(tonumber(fields.n) or 0), gm = cleanName(fields.gm) }
    for _, kind in ipairs(Roles.KINDS) do
        local seen, names = {}, {}
        for _, name in ipairs(type(fields[kind]) == "table" and fields[kind] or {}) do
            name = cleanName(name)
            if name and not seen[name] and #names < Roles.MAX_NAMES then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        table.sort(names)
        list[kind] = names
    end
    -- name -> signature public key (hex, lower case). Any name may carry one; whether it may
    -- sign offers is the publisher role's question, asked separately.
    list.keys = {}
    local count = 0
    for name, hex in pairs(type(fields.keys) == "table" and fields.keys or {}) do
        name = cleanName(name)
        if name and validKey(hex) and count < Roles.MAX_NAMES then
            list.keys[name] = hex:lower()
            count = count + 1
        end
    end
    return list
end

-- Reads a GBAROLES1 list's names, for one purpose only: the guild master's own client moving
-- its saved list to GBAROLES2 by signing it afresh. Never used to trust anything received.
function Roles.parseLegacy(text)
    if type(text) ~= "string" then return nil end
    local n, gm, rest = text:match("^GBAROLES1|(%d+)|([^|]*)|(.*)$")
    if not n then return nil end
    local fields = { n = tonumber(n), gm = gm }
    for kind, names in rest:gmatch("(%a+)=([^|]*)") do
        if validKind[kind] then
            local list = {}
            for name in names:gmatch("[^,]+") do list[#list + 1] = name end
            fields[kind] = list
        end
    end
    return Roles.newList(fields)
end

-- A copy of a list, numbered one higher, with one name's signature key set.
function Roles.withKey(list, name, hex)
    local fields = { n = (list and list.n or 0) + 1, gm = list and list.gm, keys = {} }
    for _, kind in ipairs(Roles.KINDS) do fields[kind] = list and list[kind] or {} end
    for n, k in pairs(list and list.keys or {}) do fields.keys[n] = k end
    name = cleanName(name)
    if name and validKey(hex) then fields.keys[name] = hex:lower() end
    return Roles.newList(fields)
end

-- The exact bytes that are signed. Deterministic: the same list always gives the same text.
function Roles.canonical(list)
    local parts = { Roles.TAG, tostring(list.n), list.gm or "" }
    for _, kind in ipairs(Roles.KINDS) do
        parts[#parts + 1] = kind .. "=" .. table.concat(list[kind] or {}, ",")
    end
    local names = {}
    for name in pairs(list.keys or {}) do names[#names + 1] = name end
    table.sort(names)
    for i, name in ipairs(names) do names[i] = name .. ":" .. list.keys[name] end
    parts[#parts + 1] = "keys=" .. table.concat(names, ",")
    return table.concat(parts, "|")
end

function Roles.parse(text)
    if type(text) ~= "string" then return nil end
    local fields = {}
    local tag, n, gm, rest = text:match("^([^|]+)|(%d+)|([^|]*)|(.*)$")
    if tag ~= Roles.TAG then return nil end
    fields.n, fields.gm = tonumber(n), gm
    for kind, names in rest:gmatch("(%a+)=([^|]*)") do
        if validKind[kind] then
            local list = {}
            for name in names:gmatch("[^,]+") do list[#list + 1] = name end
            fields[kind] = list
        elseif kind == "keys" then
            fields.keys = {}
            for name, hex in names:gmatch("([^,:]+):([^,]+)") do fields.keys[name] = hex end
        end
    end
    local list = Roles.newList(fields)
    -- A list that does not round-trip exactly was not written by this code; refuse it.
    if Roles.canonical(list) ~= text then return nil end
    return list
end

-- Signs a list with the guild master's 32-byte seed. Returns the wire form:
-- { text = canonical, sig = hex, key = hex }.
function Roles.sign(list, seed)
    local public = Ed25519.publicKey(seed)
    local text = Roles.canonical(list)
    return { text = text, sig = Crypto.toHex(Ed25519.sign(text, seed, public)), key = Crypto.toHex(public) }
end

-- A client's view: the pinned guild master key and the best list verified against it.
local Store = {}
Store.__index = Store
Roles.Store = Store

function Roles.newStore(saved)
    local s = setmetatable({ pinned = nil, gm = nil, signed = nil, list = nil }, Store)
    s:load(saved)
    return s
end

-- Folds in a saved copy. Never replaces a pin already held, and a saved list is taken only if
-- it verifies and is newer, so loading from two addons' saves only ever adds.
function Store:load(saved)
    if type(saved) ~= "table" then return end
    if not self.pinned and type(saved.pinned) == "string" and #saved.pinned == 64 then
        self.pinned, self.gm = saved.pinned, cleanName(saved.gm)
    end
    if type(saved.signed) == "table" then self:accept(saved.signed) end
end

function Store:export()
    return { pinned = self.pinned, gm = self.gm, signed = self.signed }
end

-- Forgets the pin and the list, for a character now in a different guild: another guild's
-- master and list say nothing about this one (docs/fix-plan.md, I1, G1).
function Store:reset()
    self.pinned, self.gm, self.signed, self.list = nil, nil, nil, nil
end

-- Pins `keyHex` as the guild master's, when `from` is the character the server stamped and
-- the roster says `from` is at rank 0. A different key from the same or a new rank-0
-- character replaces the old one: the guild master can re-key, and a new guild master takes
-- over. Returns true when the pin changed.
function Store:pin(keyHex, from, fromRank)
    if fromRank ~= 0 or type(keyHex) ~= "string" or #keyHex ~= 64 or keyHex:find("[^%x]") then return false end
    from = cleanName(from)
    if not from then return false end
    if self.pinned == keyHex and self.gm == from then return false end
    local newGM = self.gm ~= nil and self.gm ~= from
    self.pinned, self.gm = keyHex, from
    -- A list signed by a previous guild master's key no longer speaks for the guild.
    if newGM or (self.signed and self.signed.key ~= keyHex) then self.signed, self.list = nil, nil end
    return true
end

-- Everything accept checks except the signature itself: pinned key, shape, parse, newer.
-- Returns the parsed list, or nil and why. Cheap; the signature is the expensive part.
function Store:precheck(signed)
    if not self.pinned then return nil, "no guild master key pinned yet" end
    if type(signed) ~= "table" or type(signed.text) ~= "string" or type(signed.sig) ~= "string" then
        return nil, "not a signed list"
    end
    if signed.key ~= self.pinned then return nil, "signed by a key that is not the guild master's" end
    local list = Roles.parse(signed.text)
    if not list then return nil, "not a role list" end
    if self.list and list.n <= self.list.n then return nil, "not newer than the list held" end
    return list
end

-- Whether a signed list's signature is the pinned key's. Slow: in game, run it as a job.
function Roles.verifySigned(signed)
    local sig, key = Crypto.fromHex(signed.sig), Crypto.fromHex(signed.key)
    return sig ~= nil and key ~= nil and Ed25519.verify(sig, signed.text, key) == true
end

-- Takes a signed list if it verifies against the pinned key and is newer. Returns the list,
-- or nil and why. `verified` is true only when the caller has just run Roles.verifySigned on
-- this list itself (in game, as a job spread across frames); otherwise it is checked here.
function Store:accept(signed, verified)
    local list, why = self:precheck(signed)
    if not list then return nil, why end
    if not verified and not Roles.verifySigned(signed) then
        return nil, "the signature does not verify"
    end
    self.signed = { text = signed.text, sig = signed.sig, key = signed.key }
    self.list = list
    return list
end

-- A name's stamped signature key (hex), or nil when the list in force has none for it.
function Store:keyOf(name)
    local list = self.list
    name = cleanName(name)
    if not list or not name then return nil end
    return list.keys and list.keys[name] or nil
end

-- The role question, for Authority. Returns true or false when the list decides, or nil when
-- there is no list and rank must decide.
function Store:has(name, kind)
    local list = self.list
    if not list then return nil end
    name = cleanName(name)
    if not name then return false end
    if name == list.gm or name == self.gm then return true end
    for _, n in ipairs(list[kind] or {}) do if n == name then return true end end
    return false
end

if ns then ns.Roles = Roles end
return Roles
