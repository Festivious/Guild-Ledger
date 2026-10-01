-- Syndicator — cross-character inventory. A genuine data-provider addon with a clean
-- public API, so bag scanning is never rebuilt here.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local Syndicator = { name = "Syndicator" }

local function api(env)
    return Adapter.field(env.global("Syndicator"), "API")
end

function Syndicator.detect(env)
    if type(api(env)) ~= "table" then return false end
    local version = env.metadata("Syndicator", "Version")
    return true, version
end

function Syndicator.isReady(env)
    local fn = Adapter.field(api(env), "IsReady")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn)
end

function Syndicator.inventoryByItemID(env, itemID)
    local fn = Adapter.field(api(env), "GetInventoryInfoByItemID")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, itemID)
end

if ns and ns.Spokes then ns.Spokes:register(Syndicator) end
return Syndicator
