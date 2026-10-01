-- Map-relative coordinate packing. No WoW API use: runs under plain Lua 5.1 for tests.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local floor = math.floor

local Coords = {}

-- Storage precision: 4 decimals (~0.01% of zone width), the GatherMate2 convention,
-- which HandyNotes also consumes unchanged.
Coords.STORE_SCALE = 10000
-- Merge-key precision: deliberately coarser so near-duplicate observations of one
-- physical thing hash into the same bucket without an O(n) radius scan.
Coords.BUCKET_SCALE = 1000

local function clamp(v)
    if v ~= v then return 0 end -- NaN
    if v < 0 then return 0 end
    if v > 0.9999 then return 0.9999 end
    return v
end

function Coords.pack(x, y)
    x, y = clamp(x), clamp(y)
    return floor(x * 10000 + 0.5) * 1000000 + floor(y * 10000 + 0.5) * 100
end

function Coords.unpack(id)
    return floor(id / 1000000) / 10000, floor(id % 1000000 / 100) / 10000
end

-- Separate, coarser key space. Never stored on the observation itself.
function Coords.bucket(x, y)
    x, y = clamp(x), clamp(y)
    return floor(x * 1000 + 0.5) * 10000 + floor(y * 1000 + 0.5)
end

if ns then ns.Coords = Coords end
return Coords
