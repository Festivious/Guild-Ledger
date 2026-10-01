-- Content-addressed record keys. No WoW API use.
local _, ns = ...

local MergeKey = {}

-- Facts with no spatial component (item metadata, trainer lists) pass bucket = nil.
local NO_BUCKET = "-"

function MergeKey.make(factType, entityID, bucket)
    return tostring(factType) .. ":" .. tostring(entityID) .. ":" .. tostring(bucket or NO_BUCKET)
end

-- A dimension the fact did not carry. Recorded as an explicit token rather than left to
-- stringify as "nil": a death with no attributable killer has to read as unknown, which is
-- Rule 3, and a key that happens to spell a Lua value is an accident waiting to collide
-- with a real one.
MergeKey.UNKNOWN = "?"

-- Builds a key from an ordered dimension list. That ORDER is permanent, exactly like a
-- fact's field order - reordering dims silently repartitions every count already stored,
-- and nothing about the corpus would look wrong afterwards.
--
-- `extras` supplies dimensions that are derived rather than stored on the fact, such as
-- the coarse spatial bucket, which the observation itself never carries.
function MergeKey.build(factCode, dims, values, extras)
    local parts = { tostring(factCode) }
    for i = 1, #dims do
        local name = dims[i]
        local value = values and values[name]
        if value == nil and extras ~= nil then value = extras[name] end
        -- Compared against nil explicitly rather than with an `or` fallback: 0 is a real
        -- value for lootState, participated, isInstance and source, and `false` would be
        -- silently rewritten as unknown by one.
        if value == nil then value = MergeKey.UNKNOWN end
        parts[#parts + 1] = tostring(value)
    end
    return table.concat(parts, ":")
end

-- A measure shares its dimensions with the count it sits beside, so the measure name is
-- the only thing separating them.
function MergeKey.measure(key, measureName)
    return key .. "#" .. tostring(measureName)
end

if ns then ns.MergeKey = MergeKey end
return MergeKey
