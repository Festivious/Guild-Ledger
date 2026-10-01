-- The provenance envelope: what makes an observation comparable to other observations.
--
-- Without this a drop seen by a level 60 in a five-man is indistinguishable from one seen
-- by a level 20 soloing, and every rate computed from the mix is quietly wrong.
--
-- Reading the environment (WoW API) is separated from building the envelope (pure) so the
-- builder can be tested outside the game.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Provenance = {}

Provenance.REQUIRED = {
    "schemaVersion", "addonVersion", "gameBuild",
    "realm", "region", "locale", "faction",
    "observerClass", "observerLevel",
}

-- Pure. Takes a plain table of environment values plus a spoke name -> version map.
function Provenance.build(env, spokes)
    local envelope = {
        schemaVersion = env.schemaVersion,
        addonVersion  = env.addonVersion,
        gameBuild     = env.gameBuild,
        realm         = env.realm,
        region        = env.region,
        locale        = env.locale,
        faction       = env.faction,
        observerClass = env.observerClass,
        observerLevel = env.observerLevel,
        groupSize     = env.groupSize or 1,
        createdAt     = env.createdAt,
        spokes        = {},
    }
    if spokes then
        for name, version in pairs(spokes) do
            envelope.spokes[name] = version
        end
    end
    return envelope
end

-- Identity of whoever observed a session, stable across sessions and unique across the
-- realm. Local episode ids (leg, encounter, group) are only unique within a session, and
-- sessionID is the login timestamp - two contributors logging in the same second would
-- otherwise collide. Qualifying by the observer makes every chain globally addressable.
--
-- This is the one personally-identifying field in the corpus. It is deliberate: a guild
-- officer has to know who submitted. Anything shared beyond the guild should hash it.
function Provenance.observerKey(context)
    if type(context) ~= "table" then return nil end
    if not context.name then return nil end
    return context.name .. "-" .. tostring(context.realm or "?")
end

function Provenance.validate(envelope)
    if type(envelope) ~= "table" then return false, "envelope is not a table" end
    for _, field in ipairs(Provenance.REQUIRED) do
        if envelope[field] == nil then
            return false, "missing required field: " .. field
        end
    end
    return true
end

-- WoW-side only. Gathers what build() needs from the live client.
function Provenance.readEnvironment(addonVersion, schemaVersion)
    local _, build = GetBuildInfo()
    local _, class = UnitClass("player")
    local faction = UnitFactionGroup("player")
    return {
        schemaVersion = schemaVersion,
        addonVersion  = addonVersion,
        gameBuild     = build,
        realm         = GetRealmName(),
        region        = GetCVar and GetCVar("portal") or "unknown",
        locale        = GetLocale(),
        faction       = faction,
        observerClass = class,
        observerLevel = UnitLevel("player"),
        groupSize     = math.max(1, GetNumGroupMembers and GetNumGroupMembers() or 1),
        createdAt     = time(),
    }
end

if ns then ns.Provenance = Provenance end
return Provenance
