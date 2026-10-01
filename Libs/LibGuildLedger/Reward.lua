-- Rewards and the claims against them. Pure, no WoW API use.
--
-- The first data model in this project that is not an observation. Everything else
-- describes something that happened in the world; a reward describes something an officer
-- is offering, and a submission describes somebody claiming it. Neither is a view over the
-- corpus.
--
-- Two records, deliberately:
--
--   Reward      what is on offer, who offered it, and what it asks for
--   Submission  a claim against one, and the state that claim is in
--
-- They are separate because a reward outlives any one claim on it, and a claim can be
-- disputed and answered without the offer changing.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Reward = {}

-- What a reward asks the addon to ATTACH. Not what it demands - that is written in words.
--
-- The demand itself is free text, because an officer asking for twenty linen, a screenshot,
-- or a Deadmines clear is asking for things no parser needs to understand: a human reads
-- the claim and judges it. The only part the addon must act on is how much telemetry to
-- package, because that is the part it has to physically gather and send.
--
-- So there is no requirement language, and there deliberately never was one. A vocabulary
-- is permanent the moment rewards exist in the wild, exactly like fact codes, and this one
-- would have been guessing at what officers want before any officer had used it.
--
-- `none` matters most and is the default. A reward asking for items or evidence needs no
-- telemetry at all, and that is the most private answer available: unsent data cannot be
-- read by anybody.
Reward.attach = {
    none    = 0,   -- nothing; the claim is items, evidence, or the officer's own eyes
    session = 1,   -- one session the player chooses
    all     = 2,   -- everything they have recorded
}

Reward.attachName = {}
for name, code in pairs(Reward.attach) do
    Reward.attachName[code] = name
end

-- Where a claim has got to. A submission is not a single irreversible shot: an officer who
-- finds a problem says so, and the player answers it.
Reward.state = {
    submitted = 1,
    disputed  = 2,
    settled   = 3,
    declined  = 4,
}

Reward.stateName = {}
for name, code in pairs(Reward.state) do
    Reward.stateName[code] = name
end

Reward.MAX_TITLE = 60
Reward.MAX_DETAIL = 200

-- The channel queues nothing, so revoking a reward is unreliable by construction: a player
-- offline when the revocation goes out keeps the stale offer forever. An expiry is the only
-- retraction that works without the other client being present to hear it.
Reward.DEFAULT_DAYS = 30

-- Rank at or above which somebody may offer a reward. Blizzard counts downward - 0 is the
-- guild master - and GRM follows the same convention, so a LOWER index is more senior.
Reward.OFFICER_RANK = 1

-- Pure, so the rule can be tested without a guild. An unknown rank is not an officer: we
-- decline to guess upward, which is the safe direction for a permission check.
function Reward.mayOffer(rankIndex, threshold)
    if type(rankIndex) ~= "number" then return false end
    return rankIndex <= (threshold or Reward.OFFICER_RANK)
end

-- Whether an offer's issuer is the character the server says sent it.
--
-- `issuer` is written inside the payload, so it says whatever the sending client wants.
-- The CHAT_MSG_ADDON sender comes from the server. An offer is kept only when the two
-- agree, and after that the issuer can be trusted as far as the sender can - which is what
-- lets a claim be whispered to it and its items mailed to it.
--
-- Names cannot contain a hyphen, so everything after the first one is the realm. The
-- server writes realms without spaces ("LivingFlame") where GetRealmName keeps them
-- ("Living Flame"), so realms are compared with spaces and hyphens removed. A missing or
-- unknown realm on either side compares on the name alone.
local function splitName(full)
    if type(full) ~= "string" or full == "" then return nil end
    local name, realm = full:match("^([^%-]+)%-(.*)$")
    if not name then return full, nil end
    if realm == "" or realm == "?" then realm = nil end
    if realm then realm = realm:gsub("[%s%-]", ""):lower() end
    return name, realm
end

function Reward.issuerMatches(issuer, sender)
    local issuerName, issuerRealm = splitName(issuer)
    local senderName, senderRealm = splitName(sender)
    if not issuerName or not senderName then return false end
    if issuerName ~= senderName then return false end
    if issuerRealm and senderRealm and issuerRealm ~= senderRealm then return false end
    return true
end

-- An entry in what a reward asks for, or what it hands over.
--
-- An item is stored as an itemID and a count, never as its name. That is Rule 1, the same
-- rule the whole corpus follows: a name is locale-bound, and an officer on an English
-- client writing "Linen Cloth" would mean nothing to a German player. An id resolves to a
-- real item link on the reader's own client, in their own language, with the icon and the
-- tooltip the game already knows how to draw.
--
-- Free text stays available because plenty of demands are not items - a screenshot, a
-- dungeon run, showing up on time. Those a person reads.
Reward.entryKind = {
    item  = 1,
    money = 2,   -- copper, the unit the game actually counts in
    text  = 3,
    spell = 4,
}

Reward.entryKindName = {}
for name, code in pairs(Reward.entryKind) do
    Reward.entryKindName[code] = name
end

-- Two caps, not one, because the client has two and running them together is what put
-- earlier layouts in the wrong place:
--
--   MAX_GIVES  10  what the quest reward row can show (QuestInfoItem1..QuestInfoItem10)
--   MAX_WANTS  12  ATTACHMENTS_MAX_SEND: the real ceiling on what a claim can ask for,
--                  because claiming ends in one send-mail action
--
-- How many offers are listed is not capped: the list pages (docs/fix-plan.md, DEC-8).
-- ATTACHMENTS_MAX_RECEIVE is 16 and is deliberately not here: nothing in this design puts
-- items into a message being read, so the receive cap never applies to us.
Reward.MAX_GIVES = 10
Reward.MAX_WANTS = 12

-- The default for a list that is neither - a claim's manifest, which is bounded by what
-- can be posted in one mail.
Reward.MAX_ENTRIES = Reward.MAX_WANTS
Reward.MAX_QUANTITY = 100000

local function positiveInt(value, limit)
    if type(value) ~= "number" then return nil end
    value = math.floor(value)
    if value < 1 then return nil end
    if limit and value > limit then value = limit end
    return value
end

local function trimmed(value, limit)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return nil end
    if #value > limit then value = value:sub(1, limit) end
    return value
end

-- Builds one validated entry, or nil and a reason.
function Reward.entry(fields)
    if type(fields) ~= "table" then return nil, "not an entry" end

    local itemID = positiveInt(fields.itemID)
    if itemID then
        return {
            kind = Reward.entryKind.item,
            itemID = itemID,
            quantity = positiveInt(fields.quantity, Reward.MAX_QUANTITY) or 1,
        }
    end

    local spellID = positiveInt(fields.spellID)
    if spellID then
        return { kind = Reward.entryKind.spell, spellID = spellID }
    end

    local money = positiveInt(fields.money)
    if money then
        return { kind = Reward.entryKind.money, money = money }
    end

    local text = trimmed(fields.text, Reward.MAX_DETAIL)
    if text then
        return { kind = Reward.entryKind.text, text = text }
    end

    return nil, "an entry needs an item, a spell, an amount or some words"
end

-- Validates a list of entries, dropping whatever does not survive. A malformed entry
-- inside an otherwise good reward should cost that entry, not the whole offer.
function Reward.entries(list, limit)
    local out = {}
    limit = type(limit) == "number" and limit or Reward.MAX_ENTRIES
    if type(list) ~= "table" then return out end
    for _, fields in ipairs(list) do
        local entry = Reward.entry(fields)
        if entry then
            out[#out + 1] = entry
            if #out >= limit then break end
        end
    end
    return out
end

-- How an offer presents itself.
--
-- An offer is read before it is claimed, and the reading happens in a list of stubs where
-- a title on its own is not enough to tell one from another. So an offer carries an icon,
-- a line of flavour under the title, and a quality tier - the same five tiers the game
-- already colours items with. Reusing them means the list reads the way every other list
-- in the game reads, rather than inventing a private vocabulary for "how good is this".
--
-- The flavour line does double duty: it is the subnote in the list AND the subject line in
-- the detail header, the way a mail subject sits under its sender. One line, written once,
-- so the two can never disagree.
Reward.MAX_FLAVOR = 80
Reward.MAX_BODY = 400
Reward.MAX_ICON = 128

Reward.quality = {
    poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5,
}
Reward.MAX_QUALITY = 5
Reward.DEFAULT_QUALITY = Reward.quality.common

-- GetItemQualityColor is the real source and the UI asks it first. This is the fallback
-- for the pure side, and for a client that has somehow lost the function. The numbers are
-- Blizzard's own, so a fallback colour is not a different colour.
Reward.QUALITY_COLOR = {
    [0] = { 0.62, 0.62, 0.62 },
    [1] = { 1.00, 1.00, 1.00 },
    [2] = { 0.12, 1.00, 0.00 },
    [3] = { 0.00, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 },
    [5] = { 1.00, 0.50, 0.00 },
}

function Reward.qualityColor(quality)
    return Reward.QUALITY_COLOR[quality] or Reward.QUALITY_COLOR[Reward.DEFAULT_QUALITY]
end

-- What an offer asks of the character before it can be claimed.
--
-- Rule-based rather than hardcoded, because "level 10" is one officer's idea of a gate and
-- the next one wants warriors only, or nobody past rank 3. Each requirement is a small
-- typed record the player's own client checks against itself.
--
-- None of this is enforced anywhere but there. It cannot be: the officer reading the claim
-- is the real check and always was. What a gate buys is that nobody posts items away for a
-- reward they were never eligible for - which is the failure that actually costs somebody
-- something, because mail cannot be unsent.
Reward.requireKind = {
    level = 1,   -- a character level floor, ceiling, or both
    class = 2,   -- a class TOKEN: WARRIOR, PRIEST. Never a localised name - Rule 1.
    race  = 3,   -- a race token: Dwarf, Scourge
    rank  = 4,   -- guild rank index at or above; Blizzard counts down, so lower is senior
    note  = 5,   -- words only. Shown to the player, never enforced, never blocks a claim.
}

Reward.requireKindName = {}
for name, code in pairs(Reward.requireKind) do
    Reward.requireKindName[code] = name
end

Reward.MAX_REQUIREMENTS = 4

-- Tokens are compared upper-case on both sides. UnitClass returns WARRIOR and UnitRace
-- returns Dwarf, so an officer typing either case gets the same gate either way.
local function token(value, limit)
    local text = trimmed(value, limit or 24)
    return text and text:upper() or nil
end

-- Builds one validated requirement, or nil and a reason.
function Reward.requirement(fields)
    if type(fields) ~= "table" then return nil, "not a requirement" end

    local kind = fields.kind

    if kind == Reward.requireKind.level or (kind == nil and (fields.min or fields.max)) then
        local min = positiveInt(fields.min, 255)
        local max = positiveInt(fields.max, 255)
        if not min and not max then return nil, "a level rule needs a floor or a ceiling" end
        if min and max and min > max then return nil, "that level range is backwards" end
        return { kind = Reward.requireKind.level, min = min, max = max }
    end

    if kind == Reward.requireKind.class or (kind == nil and fields.class) then
        local class = token(fields.class)
        if not class then return nil, "a class rule needs a class" end
        return { kind = Reward.requireKind.class, class = class }
    end

    if kind == Reward.requireKind.race or (kind == nil and fields.race) then
        local race = token(fields.race)
        if not race then return nil, "a race rule needs a race" end
        return { kind = Reward.requireKind.race, race = race }
    end

    if kind == Reward.requireKind.rank or (kind == nil and fields.rank) then
        -- 0 is the guild master, so a rank ceiling is the one number here that may be zero.
        local rank = fields.rank
        if type(rank) ~= "number" then return nil, "a rank rule needs a rank" end
        rank = math.floor(rank)
        if rank < 0 then return nil, "a rank rule needs a rank" end
        return { kind = Reward.requireKind.rank, rank = rank }
    end

    local text = trimmed(fields.text, Reward.MAX_DETAIL)
    if text then return { kind = Reward.requireKind.note, text = text } end

    return nil, "a requirement needs a level, a class, a race, a rank or some words"
end

-- Validates a list, dropping what does not survive. Same rule as entries: one malformed
-- requirement costs that requirement, not the whole offer.
function Reward.requirements(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, fields in ipairs(list) do
        local req = Reward.requirement(fields)
        if req then
            out[#out + 1] = req
            if #out >= Reward.MAX_REQUIREMENTS then break end
        end
    end
    return out
end

function Reward.describeRequirement(req)
    if type(req) ~= "table" then return "?" end
    local kind = req.kind

    if kind == Reward.requireKind.level then
        if req.min and req.max then
            return string.format("level %d to %d", req.min, req.max)
        elseif req.min then
            return "level " .. req.min .. " or above"
        end
        return "level " .. tostring(req.max) .. " or below"

    elseif kind == Reward.requireKind.class then
        return (req.class:sub(1, 1) .. req.class:sub(2):lower()) .. "s only"

    elseif kind == Reward.requireKind.race then
        return (req.race:sub(1, 1) .. req.race:sub(2):lower()) .. "s only"

    elseif kind == Reward.requireKind.rank then
        return "guild rank " .. req.rank .. " or higher"
    end

    return tostring(req.text or "?")
end

function Reward.describeRequirements(reward)
    if type(reward) ~= "table" or type(reward.requires) ~= "table" then return nil end
    if #reward.requires == 0 then return nil end
    local parts = {}
    for _, req in ipairs(reward.requires) do
        parts[#parts + 1] = Reward.describeRequirement(req)
    end
    return table.concat(parts, ", ")
end

-- Does this character meet one requirement? Returns true, or false and why not.
--
-- An unknown fact about the character is a failure, not a pass. Locking a reward somebody
-- actually qualifies for costs them a /reload; unlocking one they do not costs them the
-- items they post for it, and mail cannot be unsent. That asymmetry decides the direction,
-- the same way it decides which way an unknown rank falls in mayOffer.
function Reward.meets(req, actor)
    if type(req) ~= "table" then return true end
    actor = type(actor) == "table" and actor or {}

    local kind = req.kind

    if kind == Reward.requireKind.note then
        return true  -- words are for the reader; the addon does not judge them

    elseif kind == Reward.requireKind.level then
        local level = actor.level
        if type(level) ~= "number" then return false, "cannot tell what level you are" end
        if (req.min and level < req.min) or (req.max and level > req.max) then
            return false, "you are level " .. level .. "; this wants " ..
                Reward.describeRequirement(req)
        end
        return true

    elseif kind == Reward.requireKind.class then
        local class = type(actor.class) == "string" and actor.class:upper() or nil
        if not class then return false, "cannot tell what class you are" end
        if class ~= req.class then return false, Reward.describeRequirement(req) end
        return true

    elseif kind == Reward.requireKind.race then
        local race = type(actor.race) == "string" and actor.race:upper() or nil
        if not race then return false, "cannot tell what race you are" end
        if race ~= req.race then return false, Reward.describeRequirement(req) end
        return true

    elseif kind == Reward.requireKind.rank then
        local rank = actor.rankIndex
        if type(rank) ~= "number" then return false, "cannot tell your guild rank" end
        if rank > req.rank then return false, Reward.describeRequirement(req) end
        return true
    end

    return true
end

-- Can this character claim this reward right now? Returns true, or false and every reason
-- it cannot - all of them, because fixing one and then being told about the next is a
-- worse way to learn what an offer wants.
function Reward.gate(reward, actor)
    if type(reward) ~= "table" then return false, { "no such reward" } end
    actor = type(actor) == "table" and actor or {}

    local unmet = {}

    -- Expiry belongs here rather than beside it: "can I claim this" is one question, and a
    -- caller that has to remember to ask two of them will one day ask only one.
    if Reward.hasExpired(reward, actor.now) then
        unmet[#unmet + 1] = "this offer has expired"
    end

    for _, req in ipairs(reward.requires or {}) do
        local ok, why = Reward.meets(req, actor)
        if not ok then unmet[#unmet + 1] = why or Reward.describeRequirement(req) end
    end

    return #unmet == 0, unmet
end

-- A reward's id has to be unique across every officer who might write one, and there is no
-- server to allocate ids. Same answer as the episode chain: qualify a local counter by who
-- issued it, and the pair is globally addressable without anybody coordinating.
function Reward.makeID(issuer, counter)
    if issuer == nil or type(counter) ~= "number" then return nil end
    return tostring(issuer) .. "#" .. tostring(counter)
end

-- Who posted an offer, read from its id (the issuer part of Reward.makeID). Nil for an id that
-- was not made that way. Only the poster decides an offer's claims, and a decision can arrive
-- before, or without, the offer itself, so the id is what is always there to check against.
function Reward.authorOf(id)
    if type(id) ~= "string" then return nil end
    return id:match("^(.+)#%d+$")
end

-- Builds a validated reward, or nil and a reason. Validation happens here rather than at
-- the call site because a reward arrives over the wire from somebody else's client, and
-- whatever they sent has to be treated as input rather than as data.
-- Who can read a session sent for this reward, besides its issuer: the reward is the
-- distribution list (spec: "The reward is the distribution list"). Character names only, a
-- handful at most, because each one is a key letter the player has to mail.
Reward.MAX_READERS = 4
Reward.MAX_NAME = 24

function Reward.readers(list)
    if type(list) ~= "table" then return nil end
    local out, seen = {}, {}
    for _, name in ipairs(list) do
        if type(name) == "string" then
            name = name:match("^([^%-]+)") or name
            if #name > 0 and #name <= Reward.MAX_NAME and not name:find("[%s%p%c]") and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
                if #out >= Reward.MAX_READERS then break end
            end
        end
    end
    return #out > 0 and out or nil
end

-- Everyone who gets a key letter for a session sent for this reward: the issuer first, then
-- each extra reader once. The issuer's letter rides in the claim mail itself.
function Reward.distribution(reward)
    local out, seen = {}, {}
    local issuer = type(reward) == "table" and type(reward.issuer) == "string"
        and (reward.issuer:match("^([^%-]+)") or reward.issuer) or nil
    if issuer then out[1], seen[issuer] = issuer, true end
    for _, name in ipairs(type(reward) == "table" and reward.readers or {}) do
        if not seen[name] then seen[name] = true; out[#out + 1] = name end
    end
    return out
end

-- Who may decide an offer's claims: its poster first, then each decider the poster named
-- (docs/fix-plan.md, DEC-4). Only these; nobody takes over, and a decider who has lost their
-- access is simply not asked (the caller checks access). Every one of them is mailed the claim
-- (DEC-5).
function Reward.deciderList(reward)
    local out, seen = {}, {}
    local issuer = type(reward) == "table" and type(reward.issuer) == "string"
        and (reward.issuer:match("^([^%-]+)") or reward.issuer) or nil
    if issuer then out[1], seen[issuer] = issuer, true end
    for _, name in ipairs(type(reward) == "table" and reward.deciders or {}) do
        if not seen[name] then seen[name] = true; out[#out + 1] = name end
    end
    return out
end

function Reward.isDecider(reward, name)
    if type(name) ~= "string" then return false end
    name = name:match("^([^%-]+)") or name
    for _, n in ipairs(Reward.deciderList(reward)) do
        if n == name then return true end
    end
    return false
end

-- Who an offer is for ------------------------------------------------------------------
--
-- The composer's To list: guild ranks, classes and named players, any of which counts. An
-- offer with no audience is for everyone. It decides who SEES the offer (a member outside it
-- does not list it) and who may CLAIM it (the officer refuses a claim from outside it). It is
-- not secret: the whole guild receives the offer, the way it receives every offer.
--
-- Ranks are indexes and classes are tokens (PRIEST), never the localised names, so an offer
-- written on one client means the same on another. Players are names without the realm.
Reward.MAX_AUDIENCE = 40

local function audienceNames(list, valid, max)
    local out, seen = {}, {}
    for _, v in ipairs(type(list) == "table" and list or {}) do
        v = valid(v)
        if v ~= nil and not seen[v] and #out < max then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function Reward.audience(fields)
    if type(fields) ~= "table" then return nil end
    local a = {
        ranks = audienceNames(fields.ranks, function(v)
            return type(v) == "number" and v >= 0 and v <= 9 and math.floor(v) == v and v or nil
        end, 10),
        classes = audienceNames(fields.classes, function(v)
            return type(v) == "string" and v:match("^%u+$") and v or nil
        end, 12),
        players = audienceNames(fields.players, function(v)
            if type(v) ~= "string" then return nil end
            v = v:match("^([^%-]+)") or v
            if #v == 0 or #v > 24 or v:find("[%s%p%c]") then return nil end
            return v
        end, Reward.MAX_AUDIENCE),
    }
    if #a.ranks == 0 and #a.classes == 0 and #a.players == 0 then return nil end
    return a
end

-- Whether a character is in an offer's audience. actor: { name, rankIndex, class = token }.
function Reward.inAudience(reward, actor)
    local a = type(reward) == "table" and reward.audience or nil
    if not a then return true end
    if type(actor) ~= "table" then return false end
    local name = type(actor.name) == "string" and (actor.name:match("^([^%-]+)") or actor.name) or nil
    for _, n in ipairs(a.players or {}) do if n == name then return true end end
    for _, r in ipairs(a.ranks or {}) do if r == actor.rankIndex then return true end end
    for _, c in ipairs(a.classes or {}) do if c == actor.class then return true end end
    return false
end

function Reward.new(fields)
    fields = type(fields) == "table" and fields or {}

    local title = trimmed(fields.title, Reward.MAX_TITLE)
    if not title then return nil, "a reward needs a title" end

    if fields.issuer == nil then return nil, "a reward needs an issuer" end

    -- Absent means none. A reward that forgot to say should ask for nothing, never for
    -- everything - the failure has to lean toward sending less.
    local attach = fields.attach or Reward.attach.none
    if Reward.attachName[attach] == nil then return nil, "unknown attachment" end

    local id = fields.id or Reward.makeID(fields.issuer, fields.counter)
    if id == nil then return nil, "a reward needs an id" end

    local quality = fields.quality
    if type(quality) == "number" then
        quality = math.floor(quality)
        if quality < 0 or quality > Reward.MAX_QUALITY then quality = nil end
    else
        quality = nil
    end

    -- An icon is either a texture path or a fileID, because the client takes both and an
    -- officer pasting either should get back what they pasted.
    local icon = fields.icon
    if type(icon) == "number" then
        icon = positiveInt(icon)
    else
        icon = trimmed(icon, Reward.MAX_ICON)
    end

    return {
        id = id,
        issuer = fields.issuer,
        readers = Reward.readers(fields.readers),
        -- Who besides the poster may decide its claims (docs/fix-plan.md, DEC-4). Signed with the
        -- offer like every field, so nobody can add themselves.
        deciders = Reward.readers(fields.deciders),
        title = title,
        -- Presentation, all optional: an offer carrying none of it still works, it just
        -- reads as a plain white line with a question-mark icon.
        icon = icon,
        flavor = trimmed(fields.flavor, Reward.MAX_FLAVOR),
        body = trimmed(fields.body, Reward.MAX_BODY),
        data = Reward.dataRequest(fields.data),
        quality = quality or Reward.DEFAULT_QUALITY,
        -- What the character has to be before this can be claimed. Empty means anyone.
        requires = Reward.requirements(fields.requires),
        -- What the officer wants and what they will hand over, as typed entries.
        -- Items travel as ids so they resolve in the reader's own language; anything that
        -- is not an item is words, which a person reads and the addon never parses.
        --
        -- Nothing here moves gold or items. The payout is the officer's to make by hand;
        -- this only records what was promised.
        wants = Reward.entries(fields.wants, Reward.MAX_WANTS),
        gives = Reward.entries(fields.gives, Reward.MAX_GIVES),
        attach = attach,
        -- An amended reward supersedes an older copy of the same id.
        revision = type(fields.revision) == "number" and fields.revision or 1,
        -- Removed by its issuer. Kept, not deleted, and sent like any other revision:
        -- a deletion cannot travel, and an older copy re-broadcast later would bring the
        -- offer back. Catalog:list and :count leave these out.
        retracted = fields.retracted == true or nil,
        -- Who the offer is for; nil is everyone. See Reward.audience.
        audience = Reward.audience(fields.audience),
        -- The hard-list quest this offer switches on (HardList), or nil for an officer's own
        -- offer. Signed with everything else, so it cannot be moved to a different quest.
        hardID = positiveInt(fields.hardID),
        -- The issuing officer's signature over everything above (OfferSig). Checked by the
        -- receiver, never trusted from here: a malformed one is simply dropped.
        sig = type(fields.sig) == "string" and #fields.sig == 128 and not fields.sig:find("[^%x]")
            and fields.sig:lower() or nil,
        issuedAt = type(fields.issuedAt) == "number" and fields.issuedAt or nil,
        expiresAt = type(fields.expiresAt) == "number" and fields.expiresAt or nil,
    }
end

function Reward.hasExpired(reward, now)
    if type(reward) ~= "table" or type(reward.expiresAt) ~= "number" then return false end
    return type(now) == "number" and now > reward.expiresAt
end

function Reward.describeAttachment(attach)
    if attach == Reward.attach.none then return "no data at all" end
    if attach == Reward.attach.session then return "one session you choose" end
    if attach == Reward.attach.all then return "everything you have recorded" end
    return "an unknown amount of data"
end

-- Renders one entry for a human. Takes the resolver rather than reaching for it, so the
-- officer building a reward and the player reading it produce identical wording.
function Reward.describeEntry(entry, resolve, providers)
    if type(entry) ~= "table" then return "?" end

    if entry.kind == Reward.entryKind.item then
        if resolve then return resolve.itemLink(providers, entry.itemID, entry.quantity) end
        return "item " .. tostring(entry.itemID) ..
            (entry.quantity > 1 and (" x" .. entry.quantity) or "")

    elseif entry.kind == Reward.entryKind.money then
        if resolve then return resolve.money(entry.money) end
        return tostring(entry.money) .. "c"

    elseif entry.kind == Reward.entryKind.spell then
        if resolve then return resolve.spell(providers, entry.spellID) end
        return "spell " .. tostring(entry.spellID)
    end

    return tostring(entry.text or "?")
end

function Reward.describeEntries(entries, resolve, providers)
    if type(entries) ~= "table" or #entries == 0 then return nil end
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = Reward.describeEntry(entry, resolve, providers)
    end
    return table.concat(parts, ", ")
end

-- A claim against a reward.
--
-- Separate from the reward because the offer outlives any one claim on it, and a claim can
-- be disputed and answered without the offer changing.
--
-- `sending` is a manifest, not a delivery. Items reach an officer through the actual
-- mailbox, where holding them IS the evidence; this only records what the player says they
-- are sending, so the two can be compared.
-- The letter's body, as lines --------------------------------------------------

-- What an offer reads as, once: the heading lines, the requirement lines, what to hand in
-- and what comes back, in the order and the colours a player sees them in.
--
-- It lives in Core rather than in the claim view because two different addons have to draw
-- the same words. The player's claim view renders this; so does the officer's composer, on
-- its last page, which promises to show the offer exactly as the player will see it. A
-- promise like that cannot be kept by two copies of the same code in two addons that
-- install separately - the first time one is edited the preview starts lying.
--
-- It returns DATA, not widgets: a list of { text, indent, r, g, b, gap }, plus the money and
-- whether there are item rewards, which the caller draws with the coin widget and the icon
-- row. That is what lets it be a pure function with tests, which none of the UI has.
--
-- `actor` is optional, and its absence is meaningful rather than a default. With one, each
-- requirement is coloured by whether that character meets it - green for met, red for not -
-- which is how a player knows which line is stopping them. Without one, as in the officer's
-- preview, there is no character to judge against: an offer is being looked at rather than
-- claimed, so the requirements are drawn in the same neutral ink as the rest.
local HEADING = { r = 0.35, g = 0.27, b = 0.15 }
local MET = { r = 0.1, g = 0.35, b = 0.08 }
local UNMET = { r = 0.62, g = 0.13, b = 0.1 }
local NEUTRAL = { r = 0.16, g = 0.12, b = 0.06 }

function Reward.bodyLines(reward, resolve, providers, actor)
    local lines = {}
    if type(reward) ~= "table" then return lines, 0, false end

    local function add(text, colour, indent, gap)
        lines[#lines + 1] = {
            text = text, indent = indent, gap = gap,
            r = colour and colour.r, g = colour and colour.g, b = colour and colour.b,
        }
        return lines[#lines]
    end

    if reward.body then add(reward.body, nil, nil, 8) end

    if #(reward.requires or {}) > 0 then
        add("Requires", HEADING, nil, 1)
        for _, req in ipairs(reward.requires) do
            local colour = NEUTRAL
            if actor then
                colour = Reward.meets(req, actor) and MET or UNMET
            end
            add("- " .. Reward.describeRequirement(req), colour, 10)
        end
        lines[#lines].gap = 8
    end

    if Reward.describeEntries(reward.wants, resolve, providers) then
        add("Hand in", HEADING, nil, 1)
        for _, want in ipairs(reward.wants) do
            add("- " .. Reward.describeEntry(want, resolve, providers), nil, 10)
        end
        lines[#lines].gap = 8
    end

    -- Items and money are drawn by the caller - as an icon row and a coin widget - so they
    -- are counted here rather than written out. Anything else the offer gives, which is
    -- neither an item nor gold, has only words to be shown as.
    local hasItems, money, extras = false, 0, {}
    for _, give in ipairs(reward.gives or {}) do
        if give.itemID then
            hasItems = true
        elseif give.kind == Reward.entryKind.money then
            money = money + (give.money or 0)
        else
            extras[#extras + 1] = Reward.describeEntry(give, resolve, providers)
        end
    end

    if hasItems or money > 0 or #extras > 0 then
        add("You will receive", HEADING, nil, 4)
        for _, extra in ipairs(extras) do
            add("- " .. extra, nil, 10)
        end
    end

    return lines, money, hasItems
end

-- What an offer asks the player to share ----------------------------------------

-- The data categories, in Core because two frames draw the same list: the officer ticks
-- them on the composer's last page, and the player reads them back on the claim view.
--
-- Modelled as a TREE and rendered flat. Every entry carries `children`, and while that is
-- empty it draws as one checkbox. The first category to grow parts an officer would ask for
-- separately draws as an expander, and only that one. That way nothing has to be rewritten
-- when the capture layers settle what is actually worth asking for - and nothing is hidden
-- behind a collapsed node today, which on a consent surface would mean a category nobody
-- read.
--
-- Provisional. The list cannot be final until the layers exist that turn raw capture into
-- something worth graphing, because those decide what is worth sharing at all.
-- `facts` is what each category actually sends: the fact types, by schema name, that a claim
-- gathers when an offer ticks it. What an offer did not ask for is never gathered, so it is
-- never sent and cannot be read (backbone invariant 2). A category with no facts yet is shown
-- to the player but sends nothing, because nothing captures it.
-- Every fact type the capture records belongs to one category, so everything recorded can be
-- asked for (docs/fix-plan.md, DEC-14). Fights, gathering and crafting, group make-up and world
-- facts used to belong to none, so they could never leave the player's computer (D1).
-- label: one word, kept short so the boxes fit, the same for the officer ticking it and the player agreeing to
-- it. tip: what exactly it shares, for the tooltip on both sides.
Reward.dataCategories = {
    { key = "position", label = "Movement", children = {}, facts = { "position", "zone_leg", "subzone" },
      tip = "Their path on the map, and the zones and places they passed through." },
    { key = "kills",    label = "Kills", children = {}, facts = { "kill", "loot_drop", "npc_spawn", "encounter" },
      tip = "What they killed, what it dropped, and where the mobs stood." },
    { key = "fights",   label = "Fights", children = {}, facts = { "blow", "aura", "pose", "target", "spell_cast" },
      tip = "Every hit, miss and heal in a fight, the buffs and debuffs, and what they cast." },
    { key = "health",   label = "Health", children = {}, facts = { "vitals", "player_death" },
      tip = "Their health over time, and every death with what caused it." },
    { key = "xp",       label = "Progress", children = {}, facts = { "xp_gain", "skill_up", "quest_event" },
      tip = "Experience gained, skill-ups, and quests taken and handed in." },
    { key = "gathering", label = "Gathering", children = {}, facts = { "gathered", "crafted" },
      tip = "The herbs, ore and skins they gathered, and what they crafted." },
    { key = "group",    label = "Group", children = {}, facts = { "group_member" },
      tip = "The class, level and role of each person in their group." },
    -- Only what is captured: npc_stats, item_meta, trainer_spell, quest_def and gameobject_node
    -- are fact types nothing records yet, and join here once something does.
    { key = "world",    label = "World", children = {}, facts = { "vendor_inventory", "spell_effect" },
      tip = "What vendors sold, and their spells' total damage and healing." },
    -- Nothing records these yet (no facts), so the composer does not offer them.
    { key = "stats",    label = "Character stats",    children = {}, facts = {} },
    { key = "talents",  label = "Talents",            children = {}, facts = {} },
    { key = "pet",      label = "Pet info",           children = {}, facts = {} },
    { key = "fps",      label = "FPS",                children = {}, facts = {} },
}

-- The fact type names an offer's data request covers, as a set.
function Reward.factsFor(keys)
    local out = {}
    for _, key in ipairs(Reward.dataRequest(keys)) do
        for _, name in ipairs(Reward.dataCategory(key).facts or {}) do out[name] = true end
    end
    return out
end

function Reward.dataCategory(key)
    for _, category in ipairs(Reward.dataCategories) do
        if category.key == key then return category end
    end
    return nil
end

-- A whitelist, kept to categories this build knows and free of duplicates.
--
-- Unknown keys are dropped rather than carried. An offer built on a newer client can name a
-- category this one has never heard of, and silently keeping it would mean showing a player
-- a consent list with a blank row in it - or worse, collecting against a name nothing here
-- can explain.
function Reward.dataRequest(keys)
    local out, seen = {}, {}
    for _, key in ipairs(type(keys) == "table" and keys or {}) do
        if Reward.dataCategory(key) and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    return out
end

function Reward.describeDataRequest(keys)
    local words = {}
    for _, key in ipairs(keys or {}) do
        local category = Reward.dataCategory(key)
        if category then words[#words + 1] = category.label end
    end
    if #words == 0 then return nil end
    return table.concat(words, ", ")
end

function Reward.claim(fields)
    fields = type(fields) == "table" and fields or {}

    if fields.rewardID == nil then return nil, "a claim needs a reward" end
    if fields.from == nil then return nil, "a claim needs a claimant" end

    local attach = fields.attach or Reward.attach.none
    if Reward.attachName[attach] == nil then return nil, "unknown attachment" end

    -- Claiming to attach a session without saying which one would leave the officer with
    -- nothing to look at, so it degrades to attaching nothing rather than pretending.
    if attach == Reward.attach.session and fields.sessionID == nil then
        attach = Reward.attach.none
    end

    return {
        rewardID = fields.rewardID,
        from = fields.from,
        sending = Reward.entries(fields.sending),
        note = trimmed(fields.note, Reward.MAX_DETAIL),
        attach = attach,
        sessionID = attach == Reward.attach.session and fields.sessionID or nil,
        -- The locked session handed over by the secure transport, when data is attached.
        -- The facts themselves never travel in the claim.
        transferID = attach ~= Reward.attach.none and type(fields.transferID) == "string"
            and fields.transferID:match("^%x+$") and #fields.transferID <= 16 and fields.transferID or nil,
        state = fields.state or Reward.state.submitted,
        at = type(fields.at) == "number" and fields.at or nil,
        -- Which revision of the offer this claim answers. An offer edited after the claim was
        -- made is shown as such, so the officer judges it against what the player saw
        -- (docs/fix-plan.md, D9, E6). Absent from older clients.
        revision = type(fields.revision) == "number" and fields.revision or nil,
        -- A guild quest's evidence: the facts that counted, for the officer's addon to recount
        -- (hard-quest spec, Part 3). Only well-shaped and bounded.
        evidence = Reward.evidence(fields.evidence),
    }
end

-- The most facts a quest's evidence may carry. A 200-kill quest with its loot is well inside it.
Reward.MAX_EVIDENCE = 4000

-- A claim's evidence, kept only when well shaped: { acceptedAt, facts = { [code] = { rows } },
-- sessions }. Nil for anything else or anything too big.
function Reward.evidence(ev)
    if type(ev) ~= "table" or type(ev.acceptedAt) ~= "number" or type(ev.facts) ~= "table" then return nil end
    local n = 0
    for code, rows in pairs(ev.facts) do
        if type(code) ~= "number" or type(rows) ~= "table" then return nil end
        n = n + #rows
    end
    if n > Reward.MAX_EVIDENCE then return nil end
    return { acceptedAt = ev.acceptedAt, facts = ev.facts,
        sessions = type(ev.sessions) == "table" and ev.sessions or {} }
end

-- What a claim will actually put on the wire, said in words, before it is sent. The player
-- should never have to guess - this is the whole of the consent the design rests on.
function Reward.describeClaim(claim, resolve, providers)
    local lines = {}

    local sending = Reward.describeEntries(claim.sending, resolve, providers)
    if sending then lines[#lines + 1] = "You are sending: " .. sending end
    if claim.note then lines[#lines + 1] = "Your note: " .. claim.note end

    if claim.attach == Reward.attach.none then
        lines[#lines + 1] = "No gameplay data leaves your computer."
    elseif claim.attach == Reward.attach.session then
        lines[#lines + 1] = "One session is attached: everywhere you went in it, and everything that happened."
    else
        lines[#lines + 1] = "Everything you have recorded is attached."
    end

    return lines
end

-- The catalog

local Catalog = {}
Catalog.__index = Catalog
Reward.Catalog = Catalog

function Catalog.new()
    return setmetatable({ rewards = {}, issued = 0 }, Catalog)
end

-- Adding the same reward twice is not an error and does not duplicate it. The channel
-- queues nothing, so an officer re-broadcasting so that whoever was offline catches up is
-- the normal case rather than a mistake.
function Catalog:put(reward)
    if type(reward) ~= "table" or reward.id == nil then return nil, "not a reward" end

    local held = self.rewards[reward.id]
    -- An older copy arriving late must not undo an amendment. Re-broadcasts are the normal
    -- case here, not the exception, because the channel queues nothing and an officer
    -- repeating themselves is how anyone offline ever catches up.
    -- The third return says it was ignored, so a caller does not report it as news.
    if held and (held.revision or 1) > (reward.revision or 1) then
        return reward.id, true, true
    end
    -- The same revision, unsigned, where the signed one is held: the poster's client signs its
    -- offers after posting (same revision, signature added), and a late unsigned copy must not
    -- strip it, or other officers could no longer pass the offer along.
    if held and (held.revision or 1) == (reward.revision or 1) and held.sig and not reward.sig then
        return reward.id, true, true
    end

    self.rewards[reward.id] = reward
    return reward.id, held ~= nil
end

function Catalog:get(id)
    return self.rewards[id]
end

function Catalog:remove(id)
    local had = self.rewards[id] ~= nil
    self.rewards[id] = nil
    return had
end

-- Offers still on offer. A removed one is held (see Reward.new's retracted) but not counted.
function Catalog:count()
    local n = 0
    for _, reward in pairs(self.rewards) do
        if not reward.retracted then n = n + 1 end
    end
    return n
end

local function sorted(out)
    table.sort(out, function(a, b)
        local at, bt = a.issuedAt or 0, b.issuedAt or 0
        if at ~= bt then return at > bt end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

-- Newest first where an issue time is known, then by id so the order is stable rather than
-- whatever pairs() happened to produce. Offers still on offer only: this is what players see.
function Catalog:list()
    local out = {}
    for _, reward in pairs(self.rewards) do
        if not reward.retracted then out[#out + 1] = reward end
    end
    return sorted(out)
end

-- Everything held, removed ones included. What goes on the wire in answer to a catalog
-- query, so a player who was offline when an offer was removed hears about it too.
function Catalog:all()
    local out = {}
    for _, reward in pairs(self.rewards) do out[#out + 1] = reward end
    return sorted(out)
end

-- Held and still on offer.
function Catalog:live(id)
    local reward = self.rewards[id]
    if reward and not reward.retracted then return reward end
    return nil
end

-- The issuer changes an offer. Same id, next revision, so every copy that hears it replaces
-- the one it holds. The expiry restarts: an edited offer is offered again.
function Catalog:revise(id, fields, now)
    local held = self:live(id)
    if not held then return nil, "no such offer on offer" end

    local carried = {}
    for key, value in pairs(fields or {}) do carried[key] = value end
    carried.id, carried.issuer = held.id, held.issuer
    carried.revision = (held.revision or 1) + 1
    carried.sig = nil          -- the old revision's signature does not cover this one
    carried.issuedAt = held.issuedAt
    if type(now) == "number" then carried.expiresAt = now + Reward.DEFAULT_DAYS * 86400 end

    local reward, err = Reward.new(carried)
    if not reward then return nil, err end
    self:put(reward)
    return reward
end

-- The issuer takes an offer down. The next revision, marked removed.
function Catalog:retract(id)
    local held = self:live(id)
    if not held then return nil, "no such offer on offer" end

    local carried = {}
    for key, value in pairs(held) do carried[key] = value end
    carried.revision = (held.revision or 1) + 1
    carried.sig = nil          -- the old revision's signature does not cover this one
    carried.retracted = true

    local reward, err = Reward.new(carried)
    if not reward then return nil, err end
    self:put(reward)
    return reward
end

-- Issues a new reward from this client, allocating the next local counter.
-- Carries the fields through rather than naming them.
--
-- It used to list them, and the list went stale the moment the schema grew: icon, flavour,
-- body, quality, requirements and the data request were all silently dropped here, before
-- Reward.new ever saw them. An officer would set an icon and a body, watch both appear on
-- the composer's own preview, and the player would receive neither - because the loss
-- happened between the two, in a function nobody was looking at.
--
-- Reward.new is the thing that decides what a reward may contain. This only owns the
-- counter, so a field it has never heard of reaches the validator instead of the floor.
function Catalog:issue(fields)
    -- Never below the moment of issue. The counter lives in this officer's saved data, and an
    -- officer who lost it (a new computer, a reinstall) started again at #1: members still held
    -- an old #1 at a higher revision and ignored the new one, or judged its claims against the
    -- old one (docs/fix-plan.md, I4, B1). A counter of at least the issue time cannot repeat
    -- anything issued before it, and still only ever rises.
    local before = self.issued
    self.issued = math.max(self.issued + 1, math.floor(tonumber(fields.issuedAt) or 0))

    local carried = {}
    for key, value in pairs(fields) do carried[key] = value end
    carried.counter = self.issued

    local reward, err = Reward.new(carried)
    if not reward then
        -- A rejected reward must not burn a counter.
        self.issued = before
        return nil, err
    end
    self:put(reward)
    return reward
end

-- Restores from SavedVariables. Everything is revalidated rather than trusted: the saved
-- file has been on disk, and some of these rewards arrived from another client.
function Catalog:load(rewards, issued)
    self.rewards, self.issued = {}, 0
    if type(issued) == "number" then self.issued = issued end

    if type(rewards) == "table" then
        for _, saved in pairs(rewards) do
            local reward = Reward.new(saved)
            if reward then self.rewards[reward.id] = reward end
        end
    end
    return self:count()
end

if ns then ns.Reward = Reward end
return Reward
