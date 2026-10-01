-- The guild master's side of the role list: the signing key, and changing who has which role.
--
-- Only the rank-0 character can sign. The signing seed is made the first time roles are
-- changed and saved with this account's guild data; it never leaves this computer. Every change
-- makes a new list with a higher number, signed, pinned here, and broadcast. At each login
-- the guild master announces the key and the list again, for anyone who missed them.
--
-- Every signature is a job (GBA.edJob), spread across frames: signed whole, the game stopped
-- the addon with "script ran too long" and no list was ever made. So changes finish a moment
-- after they are asked for, and say so when they do.
--
-- For now roles are changed with /gba role; a roles screen comes with the officer UI.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Roles, Crypto, Net = GBA.Roles, GBA.Crypto, GBA.Net

local seedHex = nil
local publicHex = nil         -- the seed's public key, kept so login need not recompute it
ns.persist("gmSeed", function() return seedHex end,
    function(saved) if type(saved) == "string" and #saved == 64 then seedHex = saved end end)
ns.persist("gmPublic", function() return publicHex end,
    function(saved) if type(saved) == "string" and #saved == 64 then publicHex = saved end end)

-- A GBAROLES1 list saved by an older build, kept aside so the guild master can re-sign it in the
-- new format at login instead of losing every role.
local legacy = nil
ns.persist("roles", function() return GBA.saveRolesByGuild() end, function(saved)
    if type(saved) == "table" and type(saved.signed) == "table" and type(saved.signed.text) == "string"
        and saved.signed.text:find("^GBAROLES1|") then
        legacy = Roles.parseLegacy(saved.signed.text)
    end
    -- One list per guild (RoleSync); a save from before that is taken as it was.
    GBA.loadRolesByGuild(saved)
end)

local function isGuildMaster() return GBA.ownRank() == 0 end

local function broadcast()
    GBA.shareRoleKey("GUILD")
    GBA.shareRoleList("GUILD")
end

-- The newest list asked for: in force, or still being signed. A change builds on this, so two
-- changes made before the first signature finishes do not both claim the same number.
local newest = nil
local function base()
    if newest and (not GBA.roles.list or newest.n > GBA.roles.list.n) then return newest end
    return GBA.roles.list
end

-- Signs a list as a job, then pins, accepts, sends it and tells the listeners.
-- done(list) or done(nil, why).
local function signAndSend(list, done)
    newest = list
    local seed = Crypto.fromHex(seedHex)
    GBA.edJob(function() return Roles.sign(list, seed) end, function(signed)
        publicHex = signed.key
        GBA.roles:pin(signed.key, UnitName("player"), 0)
        -- Just signed here: nothing to check.
        local accepted, why = GBA.roles:accept(signed, true)
        if accepted then
            broadcast()
            GBA.roleListChanged(accepted)
        end
        if done then done(accepted, why) end
    end)
end

-- Adds or removes one role for one name, signs the result, and sends it. The list arrives in
-- done(list) a moment later; the return value only says whether the change was taken.
function ns.changeRole(action, name, kind, done)
    if not isGuildMaster() then return nil, "only the guild master can change roles" end
    local valid = false
    for _, k in ipairs(Roles.KINDS) do if k == kind then valid = true end end
    if not valid then return nil, "roles are: " .. table.concat(Roles.KINDS, ", ") end
    name = type(name) == "string" and (name:match("^([^%-]+)") or name) or nil
    if not name or name == "" then return nil, "which character?" end
    name = name:sub(1, 1):upper() .. name:sub(2):lower()

    if not seedHex then
        seedHex = Crypto.toHex(Net.random(32))
        GBA.Print("made the guild master's role key")
    end
    local me = UnitName("player")
    local current = base() or Roles.newList({ n = 0, gm = me })
    -- Stamped signature keys carry over: a role change must not unstamp anyone.
    local fields = { n = current.n + 1, gm = me, keys = current.keys }
    for _, k in ipairs(Roles.KINDS) do
        local names = {}
        for _, n in ipairs(current[k] or {}) do
            if not (k == kind and n == name and action == "remove") then names[#names + 1] = n end
        end
        if k == kind and action == "add" then names[#names + 1] = name end
        fields[k] = names
    end
    local list = Roles.newList(fields)
    signAndSend(list, done)
    return list
end

-- Stamping signature keys -------------------------------------------------------------------
--
-- The guild master's client stamps an officer's signature key into the role list when it hears
-- it straight from that character (the server-attested sender of a SIG announcement) and the
-- list gives that name the publisher or officer role. Never the first list: a list decides
-- every role once it exists, so creating one automatically would demote everyone it left out.
-- The guild master makes the first list deliberately, by changing a role.
-- Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md.
local pending = {}            -- name -> key hex, heard and not yet stamped
local stampScheduled = false

local function mayHoldKey(list, name)
    for _, kind in ipairs({ "publisher", "officer" }) do
        for _, n in ipairs(list[kind] or {}) do if n == name then return true end end
    end
    return name == list.gm
end

local function stampPending()
    stampScheduled = false
    if not isGuildMaster() or not seedHex then return end
    local current = base()
    if not current then return end

    local next, names = current, {}
    for name, hex in pairs(pending) do
        if mayHoldKey(current, name) and (current.keys or {})[name] ~= hex then
            next = Roles.withKey(next, name, hex)
            names[#names + 1] = name
        end
    end
    pending = {}
    if #names == 0 then return end
    next.n = current.n + 1          -- one new list, however many keys it stamps
    table.sort(names)
    signAndSend(next, function(list)
        if list then
            GBA.Print(string.format("stamped the signature key of %s (role list %d)", table.concat(names, ", "), list.n))
        end
    end)
end

local function queueStamp(name, hex)
    if not isGuildMaster() or not seedHex or not base() then return end
    pending[name] = hex
    if not stampScheduled then
        stampScheduled = true
        C_Timer.After(10, stampPending)
    end
end

Net.on("SIG", function(from, text)
    local hex = text:match("^SIG:(%x+)$")
    if hex and #hex == 64 then queueStamp(from, hex:lower()) end
end)

-- The guild master's own key is stamped the same way, heard from itself.
local function stampOwn()
    local own = ns.Vault and ns.Vault.signPublic and ns.Vault.signPublic()
    if own and isGuildMaster() and GBA.roles:keyOf(UnitName("player")) ~= own then
        queueStamp(UnitName("player"), own)
    end
end
GBA.onRoleList(stampOwn)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
    C_Timer.After(8, function()
        if not (isGuildMaster() and seedHex) then return end
        local function carryOn()
            GBA.roles:pin(publicHex, UnitName("player"), 0)
            -- An old-format list from an earlier build: the same roles, signed afresh.
            if not GBA.roles.list and legacy then
                local fields = { n = legacy.n + 1, gm = UnitName("player") }
                for _, k in ipairs(Roles.KINDS) do fields[k] = legacy[k] end
                legacy = nil
                signAndSend(Roles.newList(fields), function(list)
                    if list then GBA.Print("moved the role list to the new format as list " .. list.n) end
                end)
            else
                broadcast()
            end
            stampOwn()
        end
        if publicHex then return carryOn() end
        -- Worked out once, as a job, then kept.
        local seed = Crypto.fromHex(seedHex)
        GBA.edJob(function() return Crypto.toHex(GBA.Ed25519.publicKey(seed)) end, function(hex)
            publicHex = hex
            carryOn()
        end)
    end)
end)

-- Commands ---------------------------------------------------------------------------------

local function describe()
    local list = GBA.roles.list
    if not list then
        GBA.Print("no role list yet: rank decides who is an officer")
        return
    end
    GBA.Print(string.format("role list %d, signed by %s", list.n, tostring(list.gm)))
    for _, kind in ipairs(Roles.KINDS) do
        GBA.Print(string.format("  %ss: %s", kind, #list[kind] > 0 and table.concat(list[kind], ", ") or "none"))
    end
    local stamped = {}
    for name in pairs(list.keys or {}) do stamped[#stamped + 1] = name end
    table.sort(stamped)
    GBA.Print("  signature keys stamped: " .. (#stamped > 0 and table.concat(stamped, ", ") or "none"))
end

GBA.RegisterCommand("roles", function()
    describe()
end, "the guild master's role list in force", "officer")

GBA.RegisterCommand("role", function(arg)
    local action, name, kind = (arg or ""):match("^%s*(%a+)%s+(%S+)%s+(%a+)")
    if action ~= "add" and action ~= "remove" then
        return GBA.Print("/gba role add|remove <name> <" .. table.concat(Roles.KINDS, "|") .. ">")
    end
    local taken, why = ns.changeRole(action, name, kind, function(list, err)
        if not list then return GBA.Print("|cffff4040could not sign the role list:|r " .. tostring(err)) end
        GBA.Print("signed and sent role list " .. list.n)
        describe()
    end)
    if not taken then return GBA.Print("|cffff4040" .. tostring(why) .. "|r") end
    GBA.Print("signing role list " .. taken.n .. "...")
end, "the guild master changes a role: /gba role add Holdy publisher", "officer")

-- The one slash command that ships. Roles stay a command rather than a screen, so the officer
-- addon answers /gba itself, for these two and nothing else. With the dev addon installed, its
-- /gba (loaded after this) takes the name over with the full set, which includes both.
local SHIPPED = { role = true, roles = true }

local function usage()
    GBA.Print("/gba roles  - the role list in force")
    GBA.Print("/gba role add|remove <name> <publisher|officer|reader>  - the guild master only")
end

SLASH_GUILDLEDGER1 = "/gba"
SlashCmdList["GUILDLEDGER"] = function(msg)
    local command, rest = (msg or ""):match("^%s*(%S*)%s*(.*)$")
    command = (command or ""):lower()
    local entry = SHIPPED[command] and GBA.commands[command]
    if not entry then return usage() end

    local allowed, why = GBA.mayAct(entry.scope)
    if not allowed then
        return GBA.Print(string.format("|cffff4040/gba %s is for officers|r (%s)", command, tostring(why)))
    end
    entry.handler(rest)
end
