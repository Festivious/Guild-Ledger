-- Account-wide saved data for the client: GuildLedgerAccountDB.
--
-- The capture buffer is per character (GuildLedgerDB), because a fact belongs to the
-- character who saw it. Some things belong to the account instead: the entropy pool every
-- key is drawn from, and the officer key directory. Those live here.
--
-- Each module registers its own save and load with ns.persistAccount rather than editing a
-- shared table, so no two writers can race on PLAYER_LOGOUT.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local persisted = {}
function ns.persistAccount(name, saveFn, loadFn)
    persisted[name] = { save = saveFn, load = loadFn }
end

ns.persistAccount("pool", function() return GBA.pool and GBA.pool:export() end,
    function(saved) if GBA.pool then GBA.pool:seed(saved) end end)

-- The guild master's signed role list and the key it is pinned to, one per guild (RoleSync).
ns.persistAccount("roles", function() return GBA.saveRolesByGuild and GBA.saveRolesByGuild() end,
    function(saved) if GBA.loadRolesByGuild then GBA.loadRolesByGuild(saved) end end)

-- The error log (LibGuildLedger/Errors.lua). Saved so it can be read after a session.
ns.persistAccount("errors", function() return GBA.errors end, function(saved)
    if type(saved) ~= "table" or not GBA.errors then return end
    for _, e in ipairs(saved) do
        if type(e) == "table" and #GBA.errors < (GBA.MAX_ERRORS or 50) then table.insert(GBA.errors, 1, e) end
    end
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        local db = GuildLedgerAccountDB
        if type(db) ~= "table" then return end
        for name, p in pairs(persisted) do pcall(p.load, db[name]) end
    elseif event == "PLAYER_LOGOUT" then
        local kept = {}
        for name, p in pairs(persisted) do
            local ok, value = pcall(p.save)
            if ok then kept[name] = value end
        end
        GuildLedgerAccountDB = kept
    end
end)
