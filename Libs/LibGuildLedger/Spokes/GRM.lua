-- Guild Roster Manager — who is in the guild, and what rank the guild thinks they hold.
--
-- Unlike Questie, GRM publishes a declared public surface: GRM_API.lua opens with "GRM
-- PUBLIC ACCESS API TO QUERY GRM DATABASE" and hands back deep copies rather than live
-- references. Everything used here comes from that surface, which is the one part of the
-- addon that is meant to be called from outside.
--
-- Why GRM rather than Blizzard's own guild ranks: a guild's real hierarchy is not the five
-- rank slots the game offers. GRM carries the structure a guild actually keeps - mains and
-- alts linked, custom notes, rank history - and that is the model officers already
-- maintain by hand. Reading it beats asking them to maintain a second one.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local GRM = { name = "GRM" }

local function api(env)
    return env.global("GRM_API")
end

function GRM.detect(env)
    if type(api(env)) ~= "table" then return false end
    -- The addon folder is Guild_Roster_Manager; its TOC name is what metadata answers to.
    local version = env.metadata("Guild_Roster_Manager", "Version")
    return true, version
end

-- The member record GRM holds: rank, join date, alts, notes. A deep copy, so nothing here
-- can perturb GRM's own database.
function GRM.getMember(env, name, guild)
    local fn = Adapter.field(api(env), "GetMember")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, name, guild)
end

function GRM.isGuildMember(env, name, guild)
    local fn = Adapter.field(api(env), "IsGuildMember")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, name, guild)
end

-- Mains and alts are one person. A reward earned on an alt belongs to the same member as
-- one earned on their main, and only GRM knows which characters are linked.
function GRM.getAlts(env, name, guild)
    local fn = Adapter.field(api(env), "GetMemberAlts")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, name, guild)
end

-- The rank as GRM records it. Returns rankName, rankIndex - either may be absent, and an
-- absent rank is not an error: it means we do not know, which is different from knowing
-- somebody ranks low.
function GRM.getRank(env, name, guild)
    local member = GRM.getMember(env, name, guild)
    if type(member) ~= "table" then return nil end
    return Adapter.field(member, "rankName"), Adapter.field(member, "rankIndex")
end

if ns and ns.Spokes then ns.Spokes:register(GRM) end
return GRM
