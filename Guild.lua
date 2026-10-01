local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

GBA.RegisterModule("Guild", GBA.addonVersion(addonName))

local Schema, Provenance = GBA.Schema, GBA.Provenance

-- Bumped when the saved shape changes. The marks and the corpus must never come back
-- without each other: marks that survive alone leave a receiver rejecting every re-sent
-- row as already seen with nothing to show for any of them.
local DB_VERSION = 2

local dedupe = ns.Dedupe.new()
local corpus = ns.Corpus.new()

-- Shared so the analytics frame can read it. One corpus per client, and only this file writes it.
ns.corpus = corpus
ns.dedupe = dedupe

local received = {
    transfers = 0,
    rows = 0,          -- rows handed to us
    folded = 0,        -- rows that became counts
    retained = 0,      -- rows kept raw, because folding would destroy their ordering
    duplicate = 0,     -- rows recognised and dropped
    unsequenced = 0,   -- rows with no stream to place them in
    unknownType = 0,   -- fact codes this client cannot name
    unkeyed = 0,       -- fact types with no key spec: folded nothing, silently, until now
    questXP = 0,       -- gains attributed to a quest turn-in
    refused = 0,       -- submissions overheard by a client not allowed to hold them
    lastFrom = nil,
}

-- Listed rather than derived from `received`, whose lastFrom is absent until something
-- arrives and so would not be reached by a pairs() walk at all.
ns.received = received

local COUNTERS = {
    "transfers", "rows", "folded", "retained",
    "duplicate", "unsequenced", "unknownType", "unkeyed", "questXP",
}

-- Anything else this addon keeps registers here, with its own save and load, instead of
-- editing the table below. Those entries are loaded whatever the dbVersion says: keys and
-- held sessions must survive a corpus format change, which throws the corpus away.
local persisted = {}
function ns.persist(name, saveFn, loadFn)
    persisted[name] = { save = saveFn, load = loadFn }
end

ns.persist("pool", function() return GBA.pool and GBA.pool:export() end,
    function(saved) if GBA.pool then GBA.pool:seed(saved) end end)
ns.persist("errors", function() return GBA.errors end, function() end)

-- The officer's offers and the claims against them. Here, not in the table below, because
-- they have nothing to do with the corpus format: a corpus change must not take them.
ns.persist("offers", function()
    return ns.offerCatalog and { rewards = ns.offerCatalog.rewards, issued = ns.offerCatalog.issued } or nil
end, function(saved)
    if ns.offerCatalog and type(saved) == "table" then
        local restored = ns.offerCatalog:load(saved.rewards, saved.issued)
        if restored > 0 then GBA.Print("restored " .. restored .. " reward(s) you have offered") end
    end
end)
ns.persist("claims", function()
    return ns.officerClaims and ns.officerClaims:export() or nil
end, function(saved)
    if not ns.officerClaims then return end
    ns.officerClaims:load(saved)
    local open = #ns.officerClaims:open()
    if open > 0 then GBA.Print(open .. " claim(s) waiting on you") end
end)

local function save()
    local kept = {}
    for name, p in pairs(persisted) do
        local ok, value = pcall(p.save)
        if ok then kept[name] = value end
    end
    GuildLedgerGuildDB = {
        kept = kept,
        dbVersion = DB_VERSION,
        schemaVersion = Schema.VERSION,
        streams = dedupe.streams,
        records = corpus.records,
        rows = corpus.rows,
        corpusSessions = corpus.sessions,
        episodes = corpus.episodes,
        received = received,
        -- Offers and claims are kept through ns.persist above, not here.
    }
end

local function restore()
    local db = GuildLedgerGuildDB
    if type(db) == "table" and type(db.kept) == "table" then
        for name, p in pairs(persisted) do pcall(p.load, db.kept[name]) end
    end
    -- Offers saved before they moved into kept: read once from where they were, so an
    -- officer's live offers survive the update. The next save writes them the new way.
    if type(db) == "table" and ns.offerCatalog and type(db.offers) == "table"
        and not (type(db.kept) == "table" and db.kept.offers) then
        ns.offerCatalog:load(db.offers, db.offersIssued)
    end
    if type(db) ~= "table" or db.dbVersion ~= DB_VERSION then return end

    local streams = dedupe:load(db.streams)
    local keys, rows = corpus:load(db.records, db.rows, db.corpusSessions, db.episodes)
    -- Raw rows last 30 days from arrival (docs/fix-plan.md, DEC-15).
    rows = rows - corpus:pruneRows(GBA.now())

    if type(db.received) == "table" then
        for _, key in ipairs(COUNTERS) do
            if type(db.received[key]) == "number" then received[key] = db.received[key] end
        end
        if type(db.received.lastFrom) == "string" then
            received.lastFrom = db.received.lastFrom
        end
    end

    if streams > 0 or keys > 0 then
        GBA.Print(string.format("restored %d key(s) and %d row(s) across %d session(s)",
            keys, rows, streams))
    end
end

-- Shared by the channel handler, accepted claims and the dev addon's /gba load, so every payload
-- goes through exactly the same path. Returns the audit, or nil and a reason.
local function ingest(payload, source)
    -- The codec version in the header only says the envelope is readable. Field layouts
    -- live in the schema version, and reading a v2 row with v4 field names would silently
    -- assign the wrong meaning to every value.
    local sent = payload.envelope and payload.envelope.schemaVersion
    if sent ~= Schema.VERSION then
        return nil, string.format("schema v%s, this client reads v%d",
            tostring(sent), Schema.VERSION)
    end

    local audit = corpus:ingest(payload, dedupe, GBA.now())

    received.transfers = received.transfers + 1
    received.lastFrom = source
    for _, key in ipairs(COUNTERS) do
        if audit[key] then received[key] = received[key] + audit[key] end
    end

    GBA.Print(string.format("%d rows from %s: %d folded, %d kept raw, %d already seen",
        audit.rows, tostring(source), audit.folded, audit.retained, audit.duplicate))

    if audit.questXP > 0 then
        GBA.Print(string.format("  %d experience gain(s) attributed to a quest turn-in",
            audit.questXP))
    end
    -- Each of these is a way for facts to arrive and quietly amount to nothing, which is
    -- the failure this project has hit four times. Loud, not logged.
    if audit.unkeyed > 0 then
        GBA.Print(string.format("  |cffff4040%d row(s) of a fact type with no key spec: folded nothing|r",
            audit.unkeyed))
    end
    if audit.unsequenced > 0 then
        GBA.Print(string.format("  |cffffcc00%d row(s) carried no sequence: these can arrive again|r",
            audit.unsequenced))
    end
    if audit.unknownType > 0 then
        GBA.Print(string.format("  |cffffcc00%d row(s) of a fact type this client does not know|r",
            audit.unknownType))
    end

    local sessions = type(payload.sessions) == "table" and payload.sessions or {}
    if next(sessions) then
        for id, context in pairs(sessions) do
            local who = Provenance.observerKey(context)
            GBA.Print(string.format("  observed by %s, level %s-%s (through seq %d)",
                who or "an unnamed character",
                tostring(context.levelAtStart), tostring(context.levelAtEnd),
                dedupe:highWater(who, id)))
        end
    else
        GBA.Print("  |cffffcc00no session context: observer is unknown|r")
    end

    return audit
end

-- Facts reach the corpus only through a claim an officer accepted (ns.acceptClaim below), or a
-- paste in the dev addon. There used to be a handler here that folded any "facts" message
-- whispered to an officer, checking only that the RECEIVER was one: anyone could add made-up
-- rows, credited to any name. Nothing shipped sent it any more, so it is gone
-- (docs/fix-plan.md, I9, S1, N1).
ns.ingest = ingest

-- Folding a claim, once an officer has accepted it.
--
-- Deliberately not done on arrival. The gate belongs in FRONT of ingest: a client that
-- folds a claim it has not accepted has already absorbed what the officer was meant to
-- decide on, and the fold is one-way. Disputing something already folded would mean
-- unpicking counts that cannot be unpicked.
function ns.acceptClaim(held)
    local sessions, facts = held.sessions, held.facts
    -- Credited to the claimant the server named, not to the name written inside the data
    -- (docs/fix-plan.md, I9, S2). A player's claim carries only their own character's recording,
    -- so a session that says it was played by someone else is a forgery or a doctored save, and
    -- is not counted. With no claimant known, nothing can be checked and it is taken as it is.
    if held.claimant and type(sessions) == "table" then
        local keep, dropped = {}, 0
        for id, context in pairs(sessions) do
            local name = type(context) == "table" and type(context.name) == "string" and GBA.Net.short(context.name)
            if name == GBA.Net.short(held.claimant) then keep[id] = context else dropped = dropped + 1 end
        end
        if dropped > 0 then
            local kept = {}
            for code, rows in pairs(type(facts) == "table" and facts or {}) do
                for _, row in ipairs(rows) do
                    if keep[Schema.chainValue(code, row, "sessionID")] then
                        kept[code] = kept[code] or {}
                        table.insert(kept[code], row)
                    end
                end
            end
            facts = kept
            GBA.Print(string.format("|cffff4040%d session(s) in %s's claim say they were played by someone else; not counted|r",
                dropped, held.claimant))
        end
        sessions = keep
    end
    return ingest({
        kind = Schema.messageKind.facts,
        envelope = { schemaVersion = Schema.VERSION },
        sessions = sessions,
        facts = facts,
    }, held.claimant or held.from) or { folded = 0, retained = 0 }
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then restore() end
    elseif event == "PLAYER_LOGOUT" then
        save()
    end
end)
