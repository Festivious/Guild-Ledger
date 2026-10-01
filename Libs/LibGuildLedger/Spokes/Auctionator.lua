-- Auctionator — item prices.
--
-- The auction-price calls are contracted in its public README. GetVendorPriceByItemID
-- lives in the same v1 folder but is NOT documented there, so it is treated as
-- semi-private: useful, but never assumed present.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local Auctionator = { name = "Auctionator" }

local CALLER_ID = "GuildLedger"

local function api(env)
    local a = env.global("Auctionator")
    local apiTable = Adapter.field(a, "API")
    return Adapter.field(apiTable, "v1")
end

function Auctionator.detect(env)
    if type(api(env)) ~= "table" then return false end
    local version = env.metadata("Auctionator", "Version")
    return true, version
end

function Auctionator.auctionPrice(env, itemID)
    local fn = Adapter.field(api(env), "GetAuctionPriceByItemID")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, CALLER_ID, itemID)
end

function Auctionator.vendorPrice(env, itemID)
    local fn = Adapter.field(api(env), "GetVendorPriceByItemID")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, CALLER_ID, itemID)
end

if ns and ns.Spokes then ns.Spokes:register(Auctionator) end
return Auctionator
