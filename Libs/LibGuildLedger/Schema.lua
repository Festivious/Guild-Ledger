-- Fact-table registry: the wire vocabulary both sides must agree on. No WoW API use.
--
-- Codes are permanent. Never renumber an existing fact type or reorder its fields; add
-- new ones at the end and raise Schema.VERSION. A decoder that sees a higher version than
-- it knows must refuse the payload rather than guess.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Schema = {}

-- 14: a reward carries how it presents itself (icon, flavour, body, quality tier) and
-- what it asks of the character claiming it (Reward.requireKind). Both are additive and
-- both sides survive the other's absence, but requireKind is a permanent code set like any
-- other on the wire, so the version moves with it. The check is an exact match, so the
-- guild updates together - which it already had to.
--
-- 21: the offer handshake (Summary.lua). Clients swap a summary of the offers they hold and send
-- only what the other lacks, instead of answering every request with the whole catalog.
--
-- 22: the hard quest list. An offer may carry hardID, the catalog quest it switches on, and two
-- fact types are added (gathered, crafted). An older client drops hardID, so its rebuilt
-- signature no longer matches; the exact match keeps the guild on one version.
--
-- 23: the subzone fact (the minimap's place name, written when it changes), which names the
-- playing fields and plays in the analytics frame. A new fact type, so no existing row changes
-- shape and FIELDS_VERSION stays; the version moves because the guild reads it as one.
--
-- 24: blow by blow in fights (blow, aura, pose, target, gear), so a fight can be replayed moment by
-- moment. New fact types only, recorded in fights. Spec: 2026-09-27-blow-by-blow-fights-design.md.
--
-- 25: each mob in a session has its own number (mob), from its GUID's spawn part, so two of the
-- same kind in one fight stay two: on blow, aura, target, kill and spell_cast (targetMob). Appended
-- fields, so rows stored before read it as nil and FIELDS_VERSION stays. Not a fold dimension.
Schema.VERSION = 25

-- Per-fact field layouts, versioned separately from the wire. Stored buffer entries keep
-- their values as positional arrays, so they are only invalidated when a fact's own
-- fields change - not when the chain grows. Separating the two means a chain change no
-- longer destroys a buffer that has been accumulating for days.
Schema.FIELDS_VERSION = 7

-- What killed the player. Environmental deaths are as common as mobs in Hardcore, and a
-- fall that kills at level 25 is worth as much to the corpus as a mob that does.
Schema.environment = {
    none = 0,
    falling = 1,
    drowning = 2,
    fatigue = 3,
    fire = 4,
    lava = 5,
    slime = 6,
}

-- CLEU reports these as localized-looking strings, but they are fixed English tokens.
Schema.environmentByName = {
    FALLING = Schema.environment.falling,
    DROWNING = Schema.environment.drowning,
    FATIGUE = Schema.environment.fatigue,
    FIRE = Schema.environment.fire,
    LAVA = Schema.environment.lava,
    SLIME = Schema.environment.slime,
}

-- Every fact travels with the episode it happened in, appended as a fixed suffix to its
-- own fields. Without this the nesting is recorded locally and then thrown away at
-- submission, which is what happened before: the receiver got a flat pile of facts with
-- no way to tell which run, zone or fight any of them belonged to.
--
-- groupID rides along so every fact is sliceable by composition without copying the
-- roster onto each row. Reference, not payload - the same rule as npcIDs.
-- "t" is seconds elapsed since the session began, not an absolute time: sessionID is
-- already the login timestamp, so the delta is small and cheap while still placing every
-- fact on a timeline. Without it a payload says which fight a kill belonged to but not
-- when, nor even in what order things happened - which makes replay impossible and
-- ordering guesswork.
-- "seq" is a per-session counter, assigned when the fact is buffered and stable from
-- then on. It exists because merging is idempotent but the FOLD from facts to merge
-- records is not: the receiver counts each row it is handed, so a row handed to it twice
-- is counted twice. That is not a rare accident - the capture buffer is never drained, so
-- every /gba send re-sends everything captured so far and overlapping delivery is the
-- normal case. Without seq the corpus is multiplied by however many times the player
-- pressed send.
--
-- A high-water mark alone would be enough for in-order delivery, but batch order is not
-- guaranteed, and a mark advanced by a later batch would reject an earlier one for good.
-- Losing data is worse than counting it twice, so the receiver tracks the mark plus the
-- seqs seen beyond it; see Dedupe.lua.
Schema.CHAIN = { "sessionID", "legID", "encounterID", "groupID", "t", "seq" }

-- Role as the client reports it. Classic has no real role system, so this is usually
-- unknown for other players; role is more reliably derived later from observed behaviour
-- (who healed, who took the damage) than from a self-assigned tag.
Schema.role = {
    unknown = 0,
    tank = 1,
    healer = 2,
    damage = 3,
}

-- What a payload IS. One prefix carries everything - Blizzard throttles per prefix and
-- splitting across several to gain bandwidth is a documented disconnect risk - so the
-- payload has to say what it is rather than the channel implying it.
--
-- Until now every payload was facts and the receiver assumed so. A reward arriving on that
-- assumption would be read as a fact table and fold into the corpus as garbage.
Schema.messageKind = {
    facts = 1,          -- player -> guild: observations
    reward = 2,         -- officer -> player: a reward on offer
    -- 3 was rewardRequest (officer -> player: please submit for this). Never sent; retired, and
    -- the number kept unused so no new kind takes it.
    rewardCatalog = 4,  -- officer -> player: the current set, in reply to a query
    catalogQuery = 5,   -- player -> officer: what is on offer right now?
    rewardClaim = 6,    -- player -> officer: claiming one, with whatever it attaches
    roleKey = 7,        -- guild master -> guild: the key role lists are signed with
    roleList = 8,       -- anyone -> anyone: the guild master's signed role list
    roleQuery = 9,      -- player -> officer: send me the current role list
    claimNotice = 10,   -- officer -> player: a claim awarded or declined, or an offer requeued
    claimNoticeAck = 11, -- player -> officer: that notice arrived; stop sending it
    claimAck = 12,      -- officer -> player: I have your claim (as its poster, or holding it for them)
    claimRelay = 13,    -- officer -> officer: a claim held for you while you were offline
    claimRelayAck = 14, -- poster -> holding officer: I have it now; stop holding it
    claimDecision = 15, -- officer -> officers: a claim decision I signed, for any of you to deliver
    claimNoticeDone = 16, -- officer -> officers: these decisions reached their players
    offerSummary = 17,  -- anyone -> officer, and back: per poster, how many offers and a digest
    offerList = 18,     -- officer -> anyone: one poster's offers as id@revision, where digests differ
    offerWant = 19,     -- anyone -> officer: send me these offers (the reply is a rewardCatalog)
    claimCopy = 20,     -- officer -> officers: a claim just received, so it is on more than one computer
    claimSaved = 21,    -- officer -> officers: these claims are on my disk now
    claimRefused = 22,  -- officer -> player: I could not take your claim, and why
}

Schema.messageKindName = {}
for name, code in pairs(Schema.messageKind) do
    Schema.messageKindName[code] = name
end

-- Quest lifecycle. Permanent codes: the receiver has to read these to tell a completion
-- from a quest thrown away, so they are shared vocabulary rather than the player addon's
-- private business.
Schema.questAction = {
    accepted = 1,
    turnedIn = 2,
    abandoned = 3,
}

-- Where experience came from. Which format string matched already tells us this, so
-- claiming everything is a mob kill throws away information we were handed for free.
Schema.xpSource = {
    kill = 1,
    other = 2,
    quest = 3,
    -- Derived by the receiver, never written by the player. Quest turn-ins award XP
    -- through the plain "You gain %d experience" string, which is indistinguishable from
    -- any other unnamed gain at capture time, so quest XP arrives as `other`. A real
    -- session had 125 of 227 XP from two quests reported as 0% quests.
    --
    -- The receiver pairs an `other` gain with the turn-in that follows it and records THIS
    -- code, not `quest`. The distinction is the whole of Rule 3: the corpus says what was
    -- observed, and an inference is labelled as one.
    questInferred = 4,
}

-- Instances report no uiMapID, so a dungeon kill would otherwise carry no location at
-- all. GetInstanceInfo does answer inside one, and its ids live in a different namespace
-- from uiMapIDs, so instance ids are stored negated. uiMapIDs are always positive, which
-- makes the two unambiguous in a single field.
function Schema.instanceMapID(instanceID)
    if type(instanceID) ~= "number" or instanceID <= 0 then return nil end
    return -instanceID
end

function Schema.isInstanceMap(mapID)
    return type(mapID) == "number" and mapID < 0
end

-- Returns the raw identifier and whether it came from the instance namespace.
function Schema.readMapID(mapID)
    if Schema.isInstanceMap(mapID) then return -mapID, true end
    return mapID, false
end

-- Continent, world and cosmic maps are not zones. Their coordinates live in a different
-- space from a zone's, so a sample taken on one is not comparable with anything else in
-- the corpus, and a leg spent on one is not time spent anywhere a player would name.
--
-- This is not hypothetical: GetBestMapForUnit answers with the continent for about a
-- second after login, which put a continent-scale position and a one-second zone leg into
-- every single session. Questie filters the same three types
-- (Database/Zones/zoneDB.lua), which is what confirmed the approach.
--
-- Pure, so it can be tested without the client: the caller supplies Enum.UIMapType.
-- Unknown types are treated as zones. Dropping data because an API is missing would be a
-- worse failure than keeping a map we could not classify.
Schema.NON_ZONE_MAP_TYPES = { "Cosmic", "World", "Continent" }

function Schema.isZoneMapType(mapType, uiMapType)
    if mapType == nil or type(uiMapType) ~= "table" then return true end
    for _, name in ipairs(Schema.NON_ZONE_MAP_TYPES) do
        -- Compared against nil explicitly: Enum.UIMapType.Cosmic is 0, and zero is truthy
        -- in Lua, so an "or" guard here would quietly misclassify the cosmic map.
        if uiMapType[name] ~= nil and mapType == uiMapType[name] then return false end
    end
    return true
end

-- Loot outcome codes for the kill fact. Only OBSERVED kills form the drop-rate
-- denominator: a corpse that was never opened proves nothing about what it could drop,
-- and counting it as empty would deflate every rate computed from the corpus.
Schema.lootState = {
    unobserved = 0,
    observed = 1,
}

-- UNIT_DIED fires for every creature death in range, not only ours. A mob dying proves it
-- spawned there regardless of who killed it, so all deaths are kept as spawn evidence and
-- flagged instead of discarded. Only participated kills mean anything for kill rates or
-- experience per kill.
Schema.participation = {
    bystander = 0,
    participated = 1,
}

-- name -> permanent numeric code
Schema.factType = {
    kill             = 1,
    loot_drop        = 2,
    npc_spawn        = 3,
    npc_stats        = 4,
    item_meta        = 5,
    quest_event      = 6,
    gameobject_node  = 7,
    vendor_inventory = 8,
    trainer_spell    = 9,
    xp_gain          = 10,
    skill_up         = 11,
    spell_effect     = 12,
    quest_def        = 13,
    -- Movement samples, for route and time-spent heat maps. Distinct from npc_spawn,
    -- which requires something to actually be standing there.
    position         = 14,
    -- One row per group member per roster change, referenced by the chain's groupID.
    group_member     = 15,
    -- A completed fight: how long it took and what it was.
    encounter        = 16,
    -- Time spent on one map, from entering to leaving. For an instance this is the run.
    zone_leg         = 17,
    -- Where the player died and to what. The most information-dense event in Hardcore,
    -- and the one thing no existing database can tell you: Wowhead knows a mob's stats,
    -- but nothing knows that this pull at this level is what kills people.
    player_death     = 18,
    -- Health and power as percentages, sampled over time. Percentages rather than raw
    -- values so one player's session is comparable with another's at a different level.
    -- This is what turns a replay from a moving dot into a story: an officer can see the
    -- near-death moments, and the long stretches spent drinking.
    vitals           = 19,
    -- Individual casts with a time, which Details' per-fight aggregates cannot give.
    -- Consumables are casts too, so eating, drinking, potions and bandages all land here
    -- and are identifiable by spell at read time.
    spell_cast       = 20,
    -- The player's own gathering: a herb, an ore vein, or a skinned corpse, and what it gave.
    -- One row per item looted; lootIndex 1 marks the first, so a node is counted once. Written
    -- by us from game events, never read from a spoke: GatherMate2 knows where nodes are, not
    -- what this player took from them. Spec: 2026-09-25-hard-quest-list-design.md.
    gathered         = 21,
    -- Something the player made: the recipe and what came out, where, at what level.
    crafted          = 22,
    -- The minimap's place name, when it changes: "Goldshire", "Fargodeep Mine", or "" on
    -- walking out of one. Display text in the client's language, so never a key (rule 2); it
    -- names places for people to read.
    subzone          = 23,
    -- Blow by blow, in fights only (spec 2026-09-27-blow-by-blow-fights-design.md).
    -- One hit, miss or heal, either way: what, how much, and how it landed.
    blow             = 24,
    -- A buff or debuff gained or lost, on the character or on their target.
    aura             = 25,
    -- Where the character stood, which way they faced, and whether they were moving: every half
    -- second in a fight. Positions outside fights stay with the normal sampler.
    pose             = 26,
    -- The character's target and its health, on change.
    target           = 27,
    -- One equipped slot: a snapshot at a fight's start when it differs from the last, and swaps.
    gear             = 28,
}

-- blow.dir and blow.result, and aura.who and aura.change. Permanent codes.
Schema.blowDir = { dealt = 1, taken = 2, healDealt = 3, healTaken = 4 }
Schema.blowResult = { hit = 0, crit = 1, miss = 2, dodge = 3, parry = 4, block = 5, resist = 6,
    absorb = 7, immune = 8, evade = 9 }
Schema.auraWho = { self = 1, target = 2 }
Schema.auraChange = { gained = 1, lost = 2 }

-- Field order per fact type. Records travel as positional arrays, so this order is the
-- wire format.
Schema.fields = {
    [Schema.factType.kill]             = { "npcID", "mapID", "coord", "observerLevel", "groupSize", "lootState", "participated", "mob" },
    -- observerLevel and groupSize are here because the KILL that forms this drop's
    -- denominator carries them. Without them the numerator and denominator of a drop rate
    -- have different dimensionality, so an overall rate is computable but a de-biased one
    -- never is - which is most of the point of Rule 2. A real twenty-minute session
    -- already had six observed kills spanning two levels against ten undimensioned drops.
    -- received was appended on 2026-09-25 (the looting record). Appended, not inserted: rows are
    -- positional arrays, so a row stored before it simply reads received as nil (unknown) and
    -- FIELDS_VERSION does not move - nobody's accumulated buffer is thrown away.
    [Schema.factType.loot_drop]        = { "npcID", "itemID", "quantity", "mapID", "coord", "observerLevel", "groupSize", "received" },
    [Schema.factType.npc_spawn]        = { "npcID", "mapID", "coord" },
    [Schema.factType.npc_stats]        = { "npcID", "level", "maxHealth", "rank" },
    [Schema.factType.item_meta]        = { "itemID", "quality", "itemLevel", "reqLevel" },
    [Schema.factType.quest_event]      = { "questID", "action", "observerLevel" },
    [Schema.factType.gameobject_node]  = { "objectID", "mapID", "coord", "skillReq" },
    [Schema.factType.vendor_inventory] = { "npcID", "itemID", "price", "stock" },
    [Schema.factType.trainer_spell]    = { "npcID", "spellID", "cost", "reqLevel" },
    [Schema.factType.xp_gain]          = { "amount", "source", "observerLevel" },
    [Schema.factType.skill_up]         = { "skillLine", "toValue", "viaSpellID" },
    [Schema.factType.spell_effect]     = { "spellID", "amount", "hits", "crits" },
    [Schema.factType.quest_def]        = { "questID", "questLevel", "reqLevel" },
    [Schema.factType.position]         = { "mapID", "coord" },
    [Schema.factType.group_member]     = { "classID", "level", "role" },
    [Schema.factType.encounter]        = { "mapID", "duration", "bossID", "deaths" },
    [Schema.factType.zone_leg]         = { "mapID", "duration", "isInstance", "groupSize" },
    [Schema.factType.player_death]     = { "mapID", "coord", "observerLevel", "killerNpcID", "killerSpellID", "environment", "groupSize" },
    [Schema.factType.vitals]           = { "healthPct", "powerPct", "inCombat" },
    [Schema.factType.spell_cast]       = { "spellID", "targetNpcID", "mapID", "coord", "targetMob" },
    [Schema.factType.gathered]         = { "kind", "sourceID", "itemID", "quantity", "mapID", "coord", "observerLevel", "lootIndex" },
    [Schema.factType.crafted]          = { "spellID", "itemID", "quantity", "mapID", "coord", "observerLevel" },
    [Schema.factType.subzone]          = { "mapID", "coord", "name" },
    [Schema.factType.blow]             = { "dir", "spellID", "npcID", "amount", "result", "absorbed", "overkill", "mob" },
    [Schema.factType.aura]             = { "who", "spellID", "change", "npcID", "mob" },
    [Schema.factType.pose]             = { "mapID", "coord", "facing", "moving" },
    [Schema.factType.target]           = { "npcID", "healthPct", "mob" },
    [Schema.factType.gear]             = { "slot", "itemID" },
}

-- Where each fact comes from. Every fact type must appear in exactly one of these, so
-- adding one forces a deliberate decision about who writes it. The test suite asserts
-- that everything listed as captured actually has a writer in the player addon - a gap
-- that is otherwise invisible, because a fact type with no writer looks perfectly healthy
-- until you notice the corpus has none of it.

-- Captured by us: no addon supplies these, so we must write them.
Schema.captured = {
    "kill", "loot_drop", "npc_spawn", "quest_event",
    "vendor_inventory", "xp_gain", "skill_up", "spell_effect", "position",
    "group_member", "encounter", "zone_leg", "player_death",
    "vitals", "spell_cast", "gathered", "crafted", "subzone",
    "blow", "aura", "pose", "target", "gear",
}

-- Resolved from a spoke at read time. The player addon must never write these; storing
-- them would duplicate data Questie and friends already hold, in a worse form.
Schema.resolved = {
    "npc_stats", "item_meta", "quest_def", "trainer_spell",
}

-- Declared in the schema but with no capture path yet. Listed so the gap is explicit
-- rather than discovered later by its absence.
Schema.deferred = {
    "gameobject_node",
}

-- How each fact is folded into the corpus.
--
-- The guild addon cannot keep the raw stream, so the fold is one-way: whatever is not a
-- key dimension is gone for good. That is why dimensions live in the KEY and never in the
-- value. Merge's commutativity, associativity and idempotence hold for the flat observers
-- map and nothing else, so the moment a record carried a nested breakdown there would be
-- no correct merge rule for it. Every dimensional cell is therefore its own key, and
-- kills[npcID][level][groupSize] is a view built by walking keys, not a stored shape.
--
-- Two rules govern what goes in a key:
--
--   Only CAPTURED values. Never a value resolved from a spoke. It is tempting to key
--   kills by level difference, since "mobs 4-10 levels below" is what an officer reads,
--   but npcLevel comes from Questie at read time. Baking a spoke lookup into a permanent
--   key means a missing or updated Questie poisons it forever. Capture observerLevel,
--   join to npcLevel on read.
--
--   The finest granularity affordable. Coarsening counts later is a read-time fold;
--   refining them is impossible. Observer level is stored exactly, not bucketed: sixty
--   values is nothing beside npcID and spatial cardinality, and "4-10 levels below" needs
--   the resolution.
Schema.keyDims = {
    [Schema.factType.kill]             = { "npcID", "observerLevel", "groupSize", "lootState", "participated" },
    [Schema.factType.loot_drop]        = { "npcID", "itemID", "observerLevel", "groupSize" },
    [Schema.factType.npc_spawn]        = { "npcID", "mapID", "spatialBucket" },
    [Schema.factType.spell_cast]       = { "spellID", "targetNpcID" },
    [Schema.factType.spell_effect]     = { "spellID" },
    [Schema.factType.vendor_inventory] = { "npcID", "itemID", "price" },
    [Schema.factType.xp_gain]          = { "source", "observerLevel" },
    [Schema.factType.skill_up]         = { "skillLine", "toValue" },
    [Schema.factType.group_member]     = { "classID", "level", "role" },
    [Schema.factType.encounter]        = { "mapID", "bossID" },
    [Schema.factType.zone_leg]         = { "mapID", "isInstance", "groupSize" },
    -- Where each kind of node is and what it gives, at what level: the node map and yield table
    -- the corpus is for. Placed like a spawn, by map and spatial bucket.
    [Schema.factType.gathered]         = { "kind", "sourceID", "itemID", "mapID", "spatialBucket", "observerLevel" },
    [Schema.factType.crafted]          = { "spellID", "itemID", "observerLevel" },
}

-- lootState and participated are mandatory dimensions of a kill, not decoration. If
-- observed and unobserved kills shared a key the drop-rate denominator could never be
-- recovered, and if participated kills shared one with bystanders the denominator would
-- count other players' mobs. A real session had 21 deaths of which 6 were the observer's:
-- folding all 21 would have deflated every rate in the corpus 3.5x, plausibly.
Schema.MANDATORY_KILL_DIMS = { "lootState", "participated" }

-- Magnitudes, summed per observer alongside the count. A count alone cannot answer "how
-- much XP" and a sum alone cannot answer "how many gains"; keeping both means averages
-- stay derivable, which a stored average never would.
Schema.keyMeasures = {
    [Schema.factType.loot_drop]    = { "quantity" },
    [Schema.factType.xp_gain]      = { "amount" },
    [Schema.factType.spell_effect] = { "amount", "hits", "crits" },
    [Schema.factType.encounter]    = { "duration", "deaths" },
    [Schema.factType.zone_leg]     = { "duration" },
}

-- Kept as rows with their chain intact rather than folded.
--
-- player_death and quest_event are rare enough that retention costs nothing, and folding
-- them destroys what makes them useful: an officer wants "you died here, then here, each
-- time at 20% health", not a count per cell.
--
-- position and vitals are here for a different reason. Measured on a real session,
-- position folds 311 rows into 275 keys - 1.13 rows per key - so a merge record, which
-- carries firstSeen, lastSeen and an observers table, costs MORE memory than the two
-- integers it replaced, while also destroying the ordering a replay needs. The fold's
-- value is cross-observer overlap, which one session cannot measure. Until that decision
-- is made these stay raw, because retaining now and folding later is possible and folding
-- now is not.
Schema.retained = {
    "position", "vitals", "player_death", "quest_event",
    -- Only useful in order: it says where the character was from then on.
    "subzone",
    -- A fight replayed moment by moment: all of it only means something in order.
    "blow", "aura", "pose", "target", "gear",
}

Schema.factTypeName = {}
for name, code in pairs(Schema.factType) do
    Schema.factTypeName[code] = name
end

-- Converts a named table into the positional array that goes on the wire.
function Schema.toArray(factCode, values)
    local fields = Schema.fields[factCode]
    if not fields then return nil, "unknown fact type: " .. tostring(factCode) end
    local out = {}
    for i = 1, #fields do
        out[i] = values[fields[i]]
    end
    return out
end

-- Wire form: the fact's own fields followed by the episode chain. The chain is appended
-- at a fixed offset rather than at the end of the array, because a fact may legitimately
-- end in a nil (a dungeon spawn with no coordinate) and #array would then be wrong.
-- Appends the chain to an already-positional array, returning a new array.
function Schema.withChain(factCode, array, chain)
    local fields = Schema.fields[factCode]
    if not fields then return nil, "unknown fact type: " .. tostring(factCode) end

    local out = {}
    for i = 1, #fields do
        out[i] = array[i]
    end
    for i, field in ipairs(Schema.CHAIN) do
        out[#fields + i] = chain and chain[field] or nil
    end
    return out
end

function Schema.toWire(factCode, values, chain)
    local array, err = Schema.toArray(factCode, values)
    if not array then return nil, err end
    return Schema.withChain(factCode, array, chain)
end

-- Returns the fact's named values and its episode chain.
function Schema.fromWire(factCode, array)
    local fields = Schema.fields[factCode]
    if not fields then return nil, "unknown fact type: " .. tostring(factCode) end

    local values = {}
    for i = 1, #fields do
        values[fields[i]] = array[i]
    end

    local chain = {}
    for i, field in ipairs(Schema.CHAIN) do
        chain[field] = array[#fields + i]
    end
    return values, chain
end

-- Position of each chain field within the suffix, derived from CHAIN rather than written
-- out, so appending a field cannot leave a stale offset behind.
Schema.chainIndex = {}
for i, field in ipairs(Schema.CHAIN) do
    Schema.chainIndex[field] = i
end

-- Reads a single chain field out of a wire row without rebuilding the whole fact, which
-- is what a receiver wants when it is only deciding whether it has seen the row before.
-- The chain is located from the fact's declared field count, never from #array: a fact may
-- legitimately end in a nil, which is exactly why withChain appends at a fixed offset.
function Schema.chainValue(factCode, array, field)
    local fields = Schema.fields[factCode]
    local offset = Schema.chainIndex[field]
    if not fields or not offset or type(array) ~= "table" then return nil end
    return array[#fields + offset]
end

function Schema.fromArray(factCode, array)
    local fields = Schema.fields[factCode]
    if not fields then return nil, "unknown fact type: " .. tostring(factCode) end
    local out = {}
    for i = 1, #fields do
        out[fields[i]] = array[i]
    end
    return out
end

if ns then ns.Schema = Schema end
return Schema
