-- Signing offers with an officer's signature key. Pure, no WoW API use.
--
-- Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md.
--
-- What is signed is the offer's canonical text: every field of the offer as Reward.new
-- validated it, keys sorted, every value tagged with its type and strings with their length,
-- and the signature itself left out. The officer signs that; every member rebuilds it from the
-- offer they received, after validating it the same way, and checks the signature against the
-- key the guild master stamped for the issuer. Change one character of the offer anywhere on
-- the way, and the check fails.
--
-- Signing proves who published and that nothing was changed. It hides nothing.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto, Ed25519
if ns then
    Crypto, Ed25519 = ns.Crypto, ns.Ed25519
else
    Crypto, Ed25519 = require("Crypto"), require("Ed25519")
end

local OfferSig = {}

OfferSig.TAG = "GBAOFFER1"

local encode

local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

-- One value, unambiguously. Tables that are lists keep their order; tables that are maps are
-- written in sorted key order, so the same offer always gives the same text.
encode = function(v, out)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "number" then
        out[#out + 1] = "n" .. string.format("%.17g", v) .. ";"
    elseif t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "table" then
        local array, n = isArray(v)
        if array then
            out[#out + 1] = "[" .. n .. ":"
            for i = 1, n do encode(v[i], out) end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b)
                local ta, tb = type(a), type(b)
                if ta ~= tb then return ta < tb end
                return a < b
            end)
            out[#out + 1] = "{" .. #keys .. ":"
            for _, k in ipairs(keys) do encode(k, out); encode(v[k], out) end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "?"
    end
end

-- The signed text of any record under a tag: everything but its signature. The tag keeps kinds
-- apart, so a signature over a claim decision can never pass as one over an offer.
function OfferSig.canonicalTagged(tag, record)
    local copy = {}
    for k, v in pairs(record) do
        if k ~= "sig" then copy[k] = v end
    end
    local out = { tag, "|" }
    encode(copy, out)
    return table.concat(out)
end

function OfferSig.signTagged(tag, record, seed, public)
    return Crypto.toHex(Ed25519.sign(OfferSig.canonicalTagged(tag, record), seed, public))
end

function OfferSig.verifyTagged(tag, record, keyHex)
    if type(record) ~= "table" or type(record.sig) ~= "string" or type(keyHex) ~= "string" then return false end
    local sig, key = Crypto.fromHex(record.sig), Crypto.fromHex(keyHex)
    if not sig or not key or #sig ~= 64 or #key ~= 32 then return false end
    return Ed25519.verify(sig, OfferSig.canonicalTagged(tag, record), key) == true
end

-- The signed text of a validated offer: everything but its signature.
function OfferSig.canonical(reward) return OfferSig.canonicalTagged(OfferSig.TAG, reward) end

-- Signs a validated offer. seed is the officer's 32-byte signature seed, public its public key.
-- Returns the signature as hex.
function OfferSig.sign(reward, seed, public) return OfferSig.signTagged(OfferSig.TAG, reward, seed, public) end

-- Whether a validated offer's sig was made by the key given (hex).
function OfferSig.verify(reward, keyHex) return OfferSig.verifyTagged(OfferSig.TAG, reward, keyHex) end

-- Claim decisions (award, decline, requeue): signed by the officer who made them, so any officer
-- can carry one to the player and the guild master can see, with proof, who decided what.
OfferSig.NOTICE_TAG = "GBANOTE1"

-- Only the fields that say what was decided, for whom, by whom and when: the signed part.
function OfferSig.noticeBody(n)
    return { kind = n.kind, to = n.to, rewardID = n.rewardID, at = n.at, state = n.state,
        by = n.by, signedAt = n.signedAt, sig = n.sig }
end

function OfferSig.signNotice(notice, seed, public)
    return OfferSig.signTagged(OfferSig.NOTICE_TAG, OfferSig.noticeBody(notice), seed, public)
end

function OfferSig.verifyNotice(notice, keyHex)
    return OfferSig.verifyTagged(OfferSig.NOTICE_TAG, OfferSig.noticeBody(notice), keyHex)
end

-- What a verification result is remembered by: the offer, its revision, and the signature, so
-- a new revision or a different signature is checked afresh.
function OfferSig.cacheKey(reward)
    return tostring(reward.id) .. "#" .. tostring(reward.revision) .. "#" .. tostring(reward.sig)
end

if ns then ns.OfferSig = OfferSig end
return OfferSig
