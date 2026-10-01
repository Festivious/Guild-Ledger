-- Shared capture state. Loaded after the pure modules and before the event wiring, so
-- every wiring file finds the same instances.
local _, ns = ...
if ns and ns.standDown then return end

ns.buffer = ns.Buffer.new()
ns.episodes = ns.Episodes.new()
ns.sampler = ns.Sampler.new()
ns.killLog = ns.KillLog.new()
ns.roster = ns.Roster.new()
ns.deathLog = ns.DeathLog.new()
ns.vitals = ns.Vitals.new()
ns.subzone = ns.Subzone.new()
ns.questLog = ns.QuestLog.new()

-- Who was observing, per session. The buffer can hold facts from several sessions and
-- several characters, so the observer cannot be read from whoever happens to be logged in
-- at submission time. A real submission stamped a level 25 character's 231 kills as
-- belonging to a level 1 alt, because the envelope was built at send time.
ns.sessions = {}

-- Replay mode samples position roughly every second instead of only on real movement.
-- Off by default: it multiplies position facts about thirtyfold, which is nothing for a
-- copy-paste export but real time over the addon channel.
ns.config = {
    replay = false,
    -- TESTING ONLY. Accepts a reward offer from anybody, not just an officer.
    --
    -- The rank check lives on the RECEIVING side, because the sender on a CHAT_MSG_ADDON
    -- event comes from the server and is the one identity that cannot be forged. Turning
    -- this on throws that away: any guild member can then put an offer in front of you.
    -- Off by default, announced whenever it lets something through, and worth removing
    -- before this is in anybody else's hands.
    trustAnyOffer = false,

    -- Claiming fills Blizzard's Send Mail tab in and stops there, leaving the Send button
    -- to the player. On, it sends for them after one confirmation.
    --
    -- Off by default and staying that way: the default path is the one where a person
    -- looks at the attachment slots in the frame they already trust before anything
    -- irreversible happens.
    autoSend = false,
}

-- Last position we successfully read. A mob dying is a moment we cannot retry, and the
-- map API does not always answer, so kills fall back to where we stood a moment ago
-- rather than being recorded with no location at all. A real session showed 87% of kills
-- losing their position this way, which also cost us their spawn evidence.
ns.lastPosition = nil

-- How positions were obtained, so the fallback rate is measured rather than assumed.
ns.positionStats = { live = 0, fallback = 0, none = 0 }

ns.POSITION_FALLBACK_SECONDS = 60

-- Reads the live map's type. Wrapped, because Questie's own notes are emphatic that the
-- map APIs are not guaranteed to answer, and an unreadable type must not cost us the map.
local function isZoneMap(mapID)
    local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
    if not (GBA and C_Map and C_Map.GetMapInfo) then return true end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if not ok or type(info) ~= "table" then return true end
    return GBA.Schema.isZoneMapType(info.mapType, Enum and Enum.UIMapType)
end

-- The map we are on, as a single identifier. Instances report no uiMapID, so a dungeon
-- would otherwise produce kills with no location at all; GetInstanceInfo does answer
-- there, and its ids are stored negated to keep the two namespaces apart.
function ns.resolveMapID()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    -- A continent answer falls through to the instance check rather than returning here.
    -- For the second after login that is simply "no usable map yet", and the next tick a
    -- second later has the real zone; recording nothing beats recording a position in a
    -- coordinate space nothing else in the corpus shares.
    if mapID and isZoneMap(mapID) then return mapID, false end

    if not GetInstanceInfo then return nil end
    -- GetInstanceInfo returns name, instanceType, difficultyID, difficultyName,
    -- maxPlayers, dynamicDifficulty, isDynamic, instanceID. With pcall's leading ok that
    -- puts instanceID ninth; counting one short landed on isDynamic, a boolean.
    local ok, _, instanceType, _, _, _, _, _, instanceID = pcall(GetInstanceInfo)
    if not ok or instanceType == "none" then return nil end

    local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
    return GBA and GBA.Schema.instanceMapID(instanceID) or nil, true
end

function ns.notePosition(mapID, coord, ts)
    if mapID and coord then
        ns.lastPosition = { mapID = mapID, coord = coord, ts = ts }
    end
end
