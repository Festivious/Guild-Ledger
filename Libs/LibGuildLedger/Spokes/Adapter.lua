-- Shared plumbing for spoke adapters.
--
-- Every call into a third-party addon goes through safeCall. None of these APIs are
-- covered by a stability promise: Questie's rich functions are explicitly outside its
-- Public/ contract, and Details' own API.txt says it is incomplete. A spoke that changes
-- shape, errors, or disappears must produce thinner data, never a broken addon.
--
-- The environment is injected rather than read from _G directly, so the degradation paths
-- can be tested without the game.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Adapter = {}

-- pcall semantics, plus a guard for a missing function: returns ok followed by every
-- value the call produced. Keeping pcall's shape matters because several spoke calls
-- return more than one value (detect returns present AND version).
function Adapter.safeCall(fn, ...)
    if type(fn) ~= "function" then return false, "not callable" end
    return pcall(fn, ...)
end

-- The common case: one value, or nil if anything went wrong.
function Adapter.tryCall(fn, ...)
    local ok, value = Adapter.safeCall(fn, ...)
    if not ok then return nil end
    return value
end

-- Reads a possibly-missing field off a possibly-missing table.
function Adapter.field(tbl, key)
    if type(tbl) ~= "table" then return nil end
    local ok, value = pcall(function() return tbl[key] end)
    if not ok then return nil end
    return value
end

function Adapter.meetsMinimum(version, minimum)
    if minimum == nil then return true end
    local n = tonumber(version)
    if n == nil then return false end
    return n >= minimum
end

-- The live WoW environment. Tests substitute a table of the same shape.
function Adapter.wowEnv()
    return {
        global = function(name)
            return _G[name]
        end,
        isLoaded = function(addon)
            local fn = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
            local ok, loaded = pcall(fn, addon)
            return ok and loaded and true or false
        end,
        metadata = function(addon, field)
            local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
            local ok, value = pcall(fn, addon, field)
            if not ok then return nil end
            return value
        end,
    }
end

if ns then ns.Adapter = Adapter end
return Adapter
