-- The game side of the role list, shared by both addons.
--
-- Roles (pure) decides what to trust; this moves the key and the list around:
--
--   roleKey    the guild master announces the key lists are signed with. Pinned only when
--              the server stamps it as sent by the rank-0 character.
--   roleList   a signed list. Taken from anyone, because the signature is what counts.
--   roleQuery  "send me the current list", whispered at login and reload to the officers
--              online, or to a few members when no officer is; anyone holding a list answers.
--
-- Everything goes through GBA.Channel, whisper or guild; the guild master can always speak
-- on the guild channel, and a member only ever listens there.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if not ns or not ns.loading then return end

local Roles, Codec, Schema, Channel, Net = ns.Roles, ns.Codec, ns.Schema, ns.Channel, ns.Net

ns.roles = Roles.newStore()
ns.Authority.store = ns.roles

-- Called with the list whenever a newer one comes into force, from the wire or signed here.
local listeners = {}
function ns.onRoleList(fn) listeners[#listeners + 1] = fn end
function ns.roleListChanged(list)
    for _, fn in ipairs(listeners) do pcall(fn, list) end
end

-- Takes a signed list: the cheap checks now, the signature as a job spread across frames, then
-- accepted. done(list) or done(nil, why). Every list, from the wire or from saved data, comes
-- in through here, because checking a signature whole stops the addon ("script ran too long").
function ns.acceptRoleList(signed, done)
    done = done or function() end
    local _, why = ns.roles:precheck(signed)
    if why then return done(nil, why) end
    ns.edJob(function() return Roles.verifySigned(signed) end, function(ok)
        if not ok then return done(nil, "the signature does not verify") end
        local list, why2 = ns.roles:accept(signed, true)
        if list then ns.roleListChanged(list) end
        done(list, why2)
    end)
end

-- The saved role data at login: the pin at once (no signature to check), the list through
-- acceptRoleList like any other.
function ns.loadRoles(saved)
    if type(saved) ~= "table" then return end
    ns.roles:load({ pinned = saved.pinned, gm = saved.gm })
    if type(saved.signed) == "table" then ns.acceptRoleList(saved.signed) end
end

-- Role lists by guild (docs/fix-plan.md, I1, G1, DEC-7) -------------------------------------
--
-- The pin and the list were saved per account, so on an account with characters in two guilds
-- one guild's list judged the other's officers. They are now kept per guild and only the
-- current guild's is in force. Nothing is deleted: another guild's list stays in the file, and
-- is in force again if a character of this account is back in that guild.
--
-- The guild is not known at load, only once the game has the roster, so saved lists wait here
-- until then and rank decides meanwhile, as it always did with no list. A save from before this
-- (one list, no guild) is the list of whichever guild a character is first seen in.

local byGuild = {}        -- guild key -> { saved export, ... } (one per addon that saved it)
local unlabeled = {}      -- saves from before guilds were known
local current = nil       -- the guild whose list is in force

-- "Guild Name-Realm" for this character's guild, or nil when not in one or not known yet.
function ns.guildKey()
    if type(GetGuildInfo) ~= "function" then return nil end
    local name, _, _, realm = GetGuildInfo("player")
    if type(name) ~= "string" or name == "" then return nil end
    realm = realm or (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or "?"
    return name .. "-" .. realm
end

local function add(key, entry)
    if type(entry) ~= "table" then return end
    byGuild[key] = byGuild[key] or {}
    table.insert(byGuild[key], entry)
end

-- For an addon's saved variables: every guild's list, the current one as it is now.
function ns.saveRolesByGuild()
    local out = {}
    for key, entries in pairs(byGuild) do out[key] = entries[#entries] end
    if current then out[current] = ns.roles:export() end
    return { byGuild = out, unlabeled = unlabeled[1] }
end

-- Puts in force the list of the guild this character is in, when that has changed.
local function applyGuild()
    local key = ns.guildKey()
    if key == current then return end
    -- A roster not answering yet is not leaving the guild.
    if not key and type(IsInGuild) == "function" and IsInGuild() then return end
    local had = current
    if current then byGuild[current] = { ns.roles:export() } end
    ns.roles:reset()
    current = key
    -- Listeners hear the old guild's list go; the new one is announced once its signature
    -- has been checked, by acceptRoleList, like any list.
    if had then ns.roleListChanged(nil) end
    if not key then return end
    local entries = byGuild[key]
    if not entries and #unlabeled > 0 then entries, unlabeled = unlabeled, {} end
    for _, entry in ipairs(entries or {}) do ns.loadRoles(entry) end
end

-- An addon's saved role data at load. Either shape: by guild, or one list from before. Both
-- addons save it, so this can run twice; once the guild is known, what the second brings for
-- it is loaded straight in, and the store keeps the newer list.
function ns.loadRolesByGuild(saved)
    if type(saved) ~= "table" then return end
    local mine = {}
    if type(saved.byGuild) == "table" then
        for key, entry in pairs(saved.byGuild) do
            if type(key) == "string" then
                add(key, entry)
                if key == current then mine[#mine + 1] = entry end
            end
        end
        if type(saved.unlabeled) == "table" then table.insert(unlabeled, saved.unlabeled) end
    elseif saved.pinned or saved.signed then
        table.insert(unlabeled, saved)
    end
    if not current then return applyGuild() end
    for _, entry in ipairs(mine) do ns.loadRoles(entry) end
end

local guildWatch = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_GUILD_UPDATE", "GUILD_ROSTER_UPDATE" }) do
    pcall(guildWatch.RegisterEvent, guildWatch, event)
end
guildWatch:SetScript("OnEvent", applyGuild)

local function send(payload, distribution, target)
    payload.envelope = { schemaVersion = Schema.VERSION }
    local encoded = Codec.encode(payload, Codec.MODE_CHANNEL)
    if encoded then return Channel.send(encoded, distribution, target) end
end

function ns.shareRoleKey(distribution, target)
    if ns.roles.pinned then send({ kind = Schema.messageKind.roleKey, key = ns.roles.pinned }, distribution, target) end
end

function ns.shareRoleList(distribution, target)
    if ns.roles.signed then send({ kind = Schema.messageKind.roleList, signed = ns.roles.signed }, distribution, target) end
end

Channel.registerHandler(function(sender, encoded)
    local p = Codec.decode(encoded)
    if type(p) ~= "table" then return end
    local kind = p.kind
    if kind ~= Schema.messageKind.roleKey and kind ~= Schema.messageKind.roleList
        and kind ~= Schema.messageKind.roleQuery then return end
    if not p.envelope or p.envelope.schemaVersion ~= Schema.VERSION then return end
    local who = Net.short(sender)

    if kind == Schema.messageKind.roleKey then
        if ns.roles:pin(p.key, who, ns.rosterRankOf(who)) then
            ns.Print("pinned the guild master's role key, from " .. who)
        end
    elseif kind == Schema.messageKind.roleList then
        -- Straight from the guild master with no key pinned yet: the stamp introduces it.
        if not ns.roles.pinned and type(p.signed) == "table" and ns.rosterRankOf(who) == 0 then
            ns.roles:pin(p.signed.key, who, 0)
        end
        ns.acceptRoleList(p.signed, function(list)
            if list then ns.Print("the guild master's role list " .. list.n .. " is now in force") end
        end)
    elseif kind == Schema.messageKind.roleQuery then
        -- Answered by anyone who holds a list, not only officers: the signature is what is
        -- checked, never the carrier, and a guild whose officers sit below rank 1 had nobody the
        -- asker would ask (docs/fix-plan.md, I2, R-1). The key still pins only from rank 0.
        ns.shareRoleKey("WHISPER", who)
        ns.shareRoleList("WHISPER", who)
    end
end)

-- Up to `max` guild members online now, this character left out.
local function onlineMembers(max)
    local out, me = {}, UnitName("player")
    if type(GetNumGuildMembers) ~= "function" then return out end
    for i = 1, (GetNumGuildMembers() or 0) do
        local fullName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
        local name = fullName and Net.short(fullName)
        if online and name and name ~= me then
            out[#out + 1] = name
            if #out >= max then break end
        end
    end
    return out
end

-- Asked at login and reload, once the roster has loaded: of the officers online, or, with none
-- online, of a few members. Not at every loading screen: a dungeon or a boat is not a login
-- (docs/fix-plan.md, D7).
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, _, isInitialLogin, isReloadingUi)
    if not (isInitialLogin or isReloadingUi) then return end
    C_Timer.After(12, function()
        local ask = ns.onlineOfficers()
        if #ask == 0 then ask = onlineMembers(3) end
        for _, name in ipairs(ask) do
            send({ kind = Schema.messageKind.roleQuery }, "WHISPER", name)
        end
    end)
end)
