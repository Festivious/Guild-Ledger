-- Session persistence, and the one capture command a player has: wipe.
--
-- SavedVariables are only written on a clean logout or /reload, so a client crash loses
-- the session. No API can force an early flush; this is an accepted limitation.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema = GBA.Schema
local buffer = ns.buffer

-- The buffer is SavedVariablesPerCharacter, not account-wide. The provenance envelope is
-- built at submission time from whoever is logged in, so a shared buffer would stamp one
-- character's observations with another's class and level - corrupting exactly the
-- de-biasing the envelope exists to provide.
local DB_VERSION = 3

local session = { startedAt = time() }
ns.session = session

-- Records who is observing for this session, so facts stay attributable to the character
-- that actually saw them rather than to whoever submits later.
local function noteSessionContext(sessionID)
    if not sessionID then return end

    local _, class = UnitClass("player")
    local _, race = UnitRace("player")
    ns.sessions[sessionID] = {
        -- Named so a session is globally addressable: episode ids are local to a session
        -- and sessionID is only a login timestamp, which two contributors can share.
        name = UnitName("player"),
        class = class,
        race = race,
        faction = UnitFactionGroup("player"),
        realm = GetRealmName(),
        levelAtStart = UnitLevel("player"),
        levelAtEnd = UnitLevel("player"),
        startedAt = sessionID,
    }
end

ns.noteSessionContext = noteSessionContext

-- PLAYER_LEVEL_UP carries the new level as its first argument, and UnitLevel("player")
-- is not reliably updated yet at the moment it fires. Taking the larger of the two is
-- right either way, and a character cannot lose a level.
local function updateSessionLevel(level)
    local current = ns.sessions[ns.episodes and ns.episodes:current().sessionID]
    if not current then return end

    local now = math.max(tonumber(level) or 0, UnitLevel("player") or 0)
    if now > 0 then current.levelAtEnd = now end
end

-- Exposed because logout is not the only moment the session summary has to be current.
-- It is read straight into every payload, so an export taken mid-session was shipping the
-- level the character logged in at: a real export said "level 1-1" for a character who
-- was level 2 by then. The facts themselves carry their own observerLevel, so this
-- understated the session rather than corrupting the corpus - but the session range is
-- exactly what an officer reads as "what did they get done tonight".
--
-- Refreshed at the two moments the answer can change or be needed: levelling up, and
-- crossing into a new zone. Note this updates the in-memory summary only. WoW writes
-- SavedVariables at a clean logout or /reload and at no other time, so nothing here - or
-- anywhere - can flush the buffer to disk early; a crash still loses the session.
ns.updateSessionLevel = updateSessionLevel

-- Persistence

local function save()
    -- Kills live in the in-memory log until they settle, so they must be converted to
    -- facts before the buffer is written or a session's denominator is lost at logout.
    if ns.flushKills then ns.flushKills(true) end
    if ns.closeOpenEpisodes then ns.closeOpenEpisodes() end

    updateSessionLevel()

    GuildLedgerDB = {
        dbVersion = DB_VERSION,
        schemaVersion = Schema.VERSION,
        -- What actually governs whether stored entries are readable.
        fieldsVersion = Schema.FIELDS_VERSION,
        config = ns.config,
        startedAt = session.startedAt,
        savedAt = time(),
        entries = buffer.entries,
        -- The sequence allocator, saved separately from the entries because it has to
        -- outlive them. A wipe empties the buffer but must not restart the numbering, or
        -- everything captured afterwards collides with numbers the receiver has already
        -- folded and is silently discarded as duplicate.
        seqBySession = buffer.seqBySession,
        -- Carried forward so facts recorded in an earlier session keep their observer.
        sessions = ns.sessions,
        -- Rewards officers have offered. Written here rather than by Rewards.lua because
        -- this assignment replaces the whole table: two writers on PLAYER_LOGOUT would
        -- race, and the loser's work would vanish.
        rewards = ns.rewardCatalog and ns.rewardCatalog.rewards or nil,
        rewardsIssued = ns.rewardCatalog and ns.rewardCatalog.issued or nil,
        -- What this character has claimed (Rewards.lua, ClaimLog).
        claims = ns.myClaims and ns.myClaims:export() or nil,
        -- Which offer signatures were already checked, so a login does not check them again.
        offerVerified = ns.exportVerified and ns.exportVerified() or nil,
        -- This character's guild quests: accepted, since when, and turned in (ZoneQuests.lua).
        hardLog = ns.hardLog and ns.hardLog:export() or nil,
    }
    -- Sessions that left the pool, packed, and a recording set aside (Archive.lua).
    -- The personal key that locks them is this character's alone, and stays in its own file.
    if ns.Archive then
        GuildLedgerDB.archive, GuildLedgerDB.setAside, GuildLedgerDB.archiveKey = ns.Archive.export()
    end
end

local function restore()
    local db = GuildLedgerDB
    if type(db) ~= "table" then return end

    -- Stored entries keep their values as positional arrays, so only a change to a fact's
    -- OWN fields makes them unreadable. A chain change alters the wire, not the store, so
    -- it must not discard a buffer that has been accumulating for days. Older saves
    -- predate fieldsVersion and carried the same number in schemaVersion.
    -- Claims first: they do not depend on how facts are laid out, so a layout change that
    -- throws the captured facts away below must not take the claims with it.
    if ns.myClaims then ns.myClaims:load(db.claims) end
    if ns.importVerified then ns.importVerified(db.offerVerified) end
    -- Like the claims, the quest log does not depend on how facts are laid out.
    if ns.hardLog then ns.hardLog:load(db.hardLog) end

    -- The archive (Archive.lua): sessions that left the pool, and a recording set aside.
    if ns.Archive then ns.Archive.load(db.archive, db.setAside, db.archiveKey) end

    if type(db.config) == "table" then
        for key, value in pairs(db.config) do ns.config[key] = value end
    end

    local storedFields = db.fieldsVersion or db.schemaVersion
    local restored = 0
    if db.dbVersion ~= DB_VERSION or storedFields ~= Schema.FIELDS_VERSION then
        -- Stored in a fact layout this build cannot read. It used to be skipped here and
        -- overwritten at the next logout, every session gone at once (docs/fix-plan.md,
        -- NEW-4): now it is set aside for 30 days. The numbering still carries on, or rows
        -- recorded from now would collide with ones already sent.
        if ns.Archive then ns.Archive.setAside(db.entries, storedFields, GBA.now()) end
        buffer:load({}, db.seqBySession)
        GBA.Print("|cffffcc00your earlier recording is in an older layout this version cannot read; it is set aside for 30 days, not deleted|r")
    else
        restored = buffer:load(db.entries, db.seqBySession)
    end
    session.startedAt = db.startedAt or session.startedAt

    if type(db.sessions) == "table" then
        for id, context in pairs(db.sessions) do
            ns.sessions[id] = context
        end
    end

    if restored > 0 then
        GBA.Print("restored " .. restored .. " facts from the previous session")
    end

    if ns.restoreRewards then ns.restoreRewards(db.rewards, db.rewardsIssued) end
end

-- Clearing the buffer is not the same as clearing what is ABOUT to be in it.
--
-- Facts do not go straight into the buffer. Kills wait in a log until their loot settles,
-- deaths wait to be drained, completed fights sit in the episode, and the open zone leg is
-- still running. Emptying only the buffer left every one of those to flush in moments
-- later, so a wipe did not wipe: the buffer refilled with things captured before it.
--
-- And it starts a new session, which matters more than it looks. The sequence allocator
-- deliberately survives a wipe so a receiver cannot mistake new facts for ones it has
-- already folded - but that leaves the stream starting at seq 956 with nothing below, a
-- gap the receiver holds open forever waiting for rows that no longer exist. A real
-- submission showed exactly that: a session whose mark never advanced past zero. A fresh
-- session starts a fresh stream at seq 1, which is both honest and clean.
local function doWipe()
    -- Held facts first, or they flush into the buffer after it has been emptied.
    --
    -- The open loot window is closed before harvesting, because harvestAll deliberately
    -- spares it - reasonable during play, wrong here, where it would leave exactly one
    -- kill alive through a wipe.
    if ns.killLog then
        if ns.killLog.endLoot then ns.killLog:endLoot() end
        if ns.killLog.harvestAll then ns.killLog:harvestAll() end
    end
    if ns.deathLog and ns.deathLog.drain then ns.deathLog:drain() end
    if ns.episodes and ns.episodes.drainCompleted then ns.episodes:drainCompleted() end

    buffer:wipe()

    local now = time()
    session.startedAt = now

    -- A new session, so the numbering starts clean rather than resuming above a gap.
    if ns.episodes and ns.episodes.startSession then
        local sessionID = ns.episodes:startSession(now)
        if noteSessionContext then noteSessionContext(sessionID) end
    end

    -- Contexts for sessions whose facts have just been discarded describe nothing.
    for id in pairs(ns.sessions) do
        if id ~= (ns.episodes and ns.episodes:current().sessionID) then
            ns.sessions[id] = nil
        end
    end

    GBA.Print("capture buffer cleared, and a new session started")
end

-- A wipe deletes the player's contribution history and nothing brings it back, so it
-- happens only behind a confirmation, the way ClaimFlow guards a send. The popup is the
-- only path to doWipe: typing the command is not the same as meaning it.
StaticPopupDialogs["GUILDLEDGER_CONFIRM_WIPE"] = {
    text = "%s",
    button1 = "Delete it",
    button2 = CANCEL or "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function() doWipe() end,
}

-- Lifecycle

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
-- Both are already registered elsewhere for other work. Listening here as well keeps
-- ownership honest: this file owns ns.sessions, so this file watches what changes it.
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then restore() end
    elseif event == "PLAYER_LOGOUT" then
        save()
    elseif event == "PLAYER_LEVEL_UP" then
        updateSessionLevel(arg1)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        updateSessionLevel()
    end
end)
