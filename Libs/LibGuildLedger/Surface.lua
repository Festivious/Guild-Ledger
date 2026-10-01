-- The shared surface: what GuildLedger and GuildLedger_Guild reach through the library.
--
-- Both addons fetch the library with LibStub("LibGuildLedger-1.0") and call it GBA, the name
-- this code has always used. Every shared module is already a field on it (GBA.Schema,
-- GBA.Codec, GBA.Reward, and so on), because each library file publishes itself there.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if not ns or not ns.loading then return end

local GBA = ns
GBA.version = "0.3.0-alpha"
GBA.schemaVersion = ns.Schema.VERSION
GBA.modules = GBA.modules or {}
GBA.commands = GBA.commands or {}

function GBA.RegisterModule(name, version)
    GBA.modules[name] = version or "?"
end

-- An addon's version from its TOC. This client no longer has the old global GetAddOnMetadata
-- (nor GetNumAddOns, GetAddOnInfo, IsAddOnLoaded): they moved to C_AddOns, and calling the
-- global killed both GuildLedger addons at line 6 in game on 2026-09-23. Always ask C_AddOns
-- first; the old global is only a fallback for a client that still has it.
function GBA.addonVersion(addonName)
    local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if type(fn) ~= "function" then return "?" end
    local ok, version = pcall(fn, addonName, "Version")
    return ok and version or "?"
end

-- Commands, registered here and dispatched ONLY by GuildLedger_Dev.
--
-- Players and officers do everything through the in-game UI. Without the dev addon there is
-- no slash command at all: registering a command only records a plain function the dev
-- addon can call, and the UI calls the same functions directly.
--
-- Every command says who it is for, because installing an addon is not a permission:
--
--   player   a guild member's own tools; the default
--   offer    making rewards and reading the claims against them
--   officer  reading and holding guild data
--   dev      diagnostics and probes
--
-- `offer` and `officer` are refused by the dev dispatcher unless Authority allows that role.
GBA.commandScope = { player = true, offer = true, officer = true, dev = true }

function GBA.RegisterCommand(name, handler, help, scope)
    scope = scope or "player"
    if not GBA.commandScope[scope] then
        error("unknown command scope " .. tostring(scope) .. " for " .. tostring(name))
    end
    GBA.commands[name] = { handler = handler, help = help, scope = scope }
end

function GBA.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00d1ffGuild Ledger|r " .. tostring(msg))
end

-- The game server's clock, in seconds, for every time that more than one player reads: when an
-- offer was posted and when it expires, when a claim was made, decided or delivered. Each
-- player's own computer clock can be minutes or hours out, and those times are compared across
-- players (docs/fix-plan.md, D8, B4). Falls back to this computer's clock outside the game.
function GBA.now()
    if type(GetServerTime) == "function" then
        local ok, t = pcall(GetServerTime)
        if ok and type(t) == "number" and t > 0 then return t end
    end
    return time()
end

-- This character's own guild rank, or nil when it cannot be read. GetGuildInfo answers
-- from a roster cache that is empty for a moment after login, and nil is treated as "not
-- an officer" everywhere it is used - a refusal the player can retry, never a grant.
function GBA.ownRank()
    if type(GetGuildInfo) ~= "function" then return nil end
    local _, _, rankIndex = GetGuildInfo("player")
    if type(rankIndex) ~= "number" then return nil end
    return rankIndex
end

-- A guild member as the roster reports them: rankIndex and online, or nil when the name
-- is not in the guild. Scanned rather than cached because the roster is small and a
-- stale rank is worse than a slow one. Matches "Name" against "Name-Realm" either way.
-- A guild member's facts for an offer's audience: { name, rankIndex, class = token, level,
-- online }, or nil when not in the guild. Same scan and name matching as rosterEntry.
function GBA.rosterMember(name)
    if type(name) ~= "string" or type(GetNumGuildMembers) ~= "function" then return nil end
    local short = name:match("^([^%-]+)") or name
    for i = 1, (GetNumGuildMembers() or 0) do
        local fullName, _, rankIndex, level, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        if fullName and (fullName == name or (fullName:match("^([^%-]+)") == short)) then
            return { name = short, rankIndex = rankIndex, class = classFile, level = level,
                online = online and true or false }
        end
    end
    return nil
end

function GBA.rosterEntry(name)
    if type(name) ~= "string" or type(GetNumGuildMembers) ~= "function" then return nil end
    local short = name:match("^([^%-]+)") or name
    local total = GetNumGuildMembers()
    for i = 1, (total or 0) do
        local fullName, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
        if fullName and (fullName == name or (fullName:match("^([^%-]+)") == short)) then
            return rankIndex, online and true or false
        end
    end
    return nil
end

function GBA.rosterRankOf(name)
    return (GBA.rosterEntry(name))
end

-- Whether a character is in the guild: true, false, or nil when it cannot be told. False only
-- when the roster is loaded and the name is not on it, so a roster still empty after login
-- revokes nobody. This character is never judged out here: other clients judge it.
function GBA.inGuild(name)
    if type(name) ~= "string" then return nil end
    local short = name:match("^([^%-]+)") or name
    if UnitName and short == UnitName("player") then return nil end
    if type(GetNumGuildMembers) ~= "function" then return nil end
    if (GetNumGuildMembers() or 0) == 0 then return nil end
    return GBA.rosterEntry(name) ~= nil
end
ns.Authority.membership = GBA.inGuild

-- Whether this client may use a role, and why not.
function GBA.mayAct(role)
    return ns.Authority.may(role, { rankIndex = GBA.ownRank(), name = UnitName and UnitName("player") })
end

-- Adapters register into this as their files load; detection waits for PLAYER_LOGIN so
-- every other addon has finished initialising.
GBA.spokes = ns.Registry.new()
ns.Spokes = GBA.spokes

GBA.RegisterModule("Lib", GBA.version)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    GBA.spokes:detectAll(ns.Adapter.wowEnv())
end)
