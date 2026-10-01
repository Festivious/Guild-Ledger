-- What a client holds, in a few bytes: the handshake that replaces "send me everything".
-- Pure, no WoW API use.
--
-- Spec: docs/superpowers/specs/2026-09-24-guild-propagation-and-soak-design.md, part 1.
--
-- Two clients that meet swap summaries: for each officer whose offers they hold, how many and a
-- short digest of which revisions. Where the digests match there is nothing to say. Where one
-- differs, the full list for that officer is sent (an id and revision per offer, no content),
-- and each side asks only for what it lacks or holds older. Nothing is sent that the other side
-- already has, and a match is itself the proof that everything arrived.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Crypto
if ns then Crypto = ns.Crypto else Crypto = require("Crypto") end

local Summary = {}

Summary.DIGEST_CHARS = 12

-- One offer as the handshake names it: id, revision, and "x" when it is a removal.
function Summary.entry(reward)
    return tostring(reward.id) .. "@" .. tostring(reward.revision or 1) .. (reward.retracted and "x" or "")
end

-- id, revision, removed, from an entry. Nil for anything else.
function Summary.parse(entry)
    if type(entry) ~= "string" then return nil end
    local id, rev, x = entry:match("^(.+)@(%d+)(x?)$")
    if not id then return nil end
    return id, tonumber(rev), x == "x"
end

-- Who posted an offer, from its id (poster#counter). Offers are grouped by it, so a new offer
-- from one officer changes one digest and leaves the rest alone.
local function authorOf(id)
    return type(id) == "string" and id:match("^(.+)#%d+$") or "?"
end
Summary.authorOf = authorOf

-- Newer is a higher revision; at one revision, a removal is newer than the live offer.
local function rank(rev, removed) return (rev or 0) * 2 + (removed and 1 or 0) end

-- The entries for each author, sorted.
function Summary.lists(rewards)
    local out = {}
    for _, reward in ipairs(rewards or {}) do
        if reward.id ~= nil then
            local a = authorOf(tostring(reward.id))
            out[a] = out[a] or {}
            table.insert(out[a], Summary.entry(reward))
        end
    end
    for _, list in pairs(out) do table.sort(list) end
    return out
end

function Summary.digest(list)
    return Crypto.toHex(Crypto.sha256(table.concat(list, "\n"))):sub(1, Summary.DIGEST_CHARS)
end

-- { [author] = { n = count, d = digest } }: what goes on the wire first.
function Summary.of(rewards)
    local out = {}
    for author, list in pairs(Summary.lists(rewards)) do
        out[author] = { n = #list, d = Summary.digest(list) }
    end
    return out
end

-- The authors whose offers the two summaries disagree on, either way, sorted.
function Summary.differs(mine, theirs)
    local out, seen = {}, {}
    for _, side in ipairs({ mine or {}, theirs or {} }) do
        for author in pairs(side) do
            if not seen[author] then
                seen[author] = true
                local a, b = (mine or {})[author], (theirs or {})[author]
                if not a or not b or a.d ~= b.d or a.n ~= b.n then out[#out + 1] = author end
            end
        end
    end
    table.sort(out)
    return out
end

-- The ids to ask for: entries on their list that this client lacks, or holds older.
-- `held(id)` returns this client's copy, or nil.
function Summary.wants(theirEntries, held)
    local out = {}
    for _, entry in ipairs(theirEntries or {}) do
        local id, rev, removed = Summary.parse(entry)
        if id then
            local mine = held(id)
            if not mine or rank(mine.revision or 1, mine.retracted) < rank(rev, removed) then out[#out + 1] = id end
        end
    end
    table.sort(out)
    return out
end

if ns then ns.Summary = Summary end
return Summary
