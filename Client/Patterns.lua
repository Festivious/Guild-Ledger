-- Builds Lua patterns from Blizzard's own format strings. No WoW API use.
--
-- Chat messages are localized, so a hard-coded English pattern captures nothing on a
-- German client and the corpus quietly loses that contributor entirely. Blizzard's format
-- globals (ERR_SKILL_UP_SI, COMBATLOG_XPGAIN_FIRSTPERSON, ...) are already localized, so
-- converting them into patterns works in every locale for free.
--
-- "Your skill in %s has increased to %d."  ->  "^Your skill in (.+) has increased to (%d+)%.$"
local _, ns = ...
if ns and ns.standDown then return end

local Patterns = {}

-- Escapes Lua pattern magic characters, leaving format specifiers intact.
local function escapeLiterals(text)
    return (text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local CAPTURES = {
    s = "(.-)",
    d = "(%d+)",
    f = "([%d%.]+)",
}

-- Specifiers are marked with a sentinel BEFORE escaping, because escaping would otherwise
-- rewrite "%1$s" into "%%1%$s" and make the specifier unrecognisable. The sentinel uses
-- control character \1, which cannot occur in a chat message.
local MARK = "\1"

-- Converts a format string into an anchored pattern plus the order of its captures.
-- Handles both plain (%s, %d) and positional (%1$s, %2$d) specifiers; localized strings
-- use the positional form to reorder arguments.
function Patterns.fromFormat(format)
    if type(format) ~= "string" then return nil end

    local order, captures = {}, {}

    local marked = format:gsub("%%(%d+)%$([sdf])", function(index, kind)
        order[#order + 1] = tonumber(index)
        captures[#captures + 1] = CAPTURES[kind] or CAPTURES.s
        return MARK .. #captures .. MARK
    end)

    local plainIndex = 0
    marked = marked:gsub("%%([sdf])", function(kind)
        plainIndex = plainIndex + 1
        order[#order + 1] = plainIndex
        captures[#captures + 1] = CAPTURES[kind] or CAPTURES.s
        return MARK .. #captures .. MARK
    end)

    -- Any % still present is a literal percent in the message, so escaping is correct now.
    local escaped = escapeLiterals(marked)

    -- A function replacement is inserted verbatim, so the capture patterns keep their
    -- single % and stay real patterns rather than literal percent matches.
    local pattern = escaped:gsub(MARK .. "(%d+)" .. MARK, function(slot)
        return captures[tonumber(slot)]
    end)

    return "^" .. pattern .. "$", order
end

-- Matches text against a format string, returning captures in DECLARED argument order
-- regardless of how the localization reordered them.
function Patterns.match(text, format)
    if type(text) ~= "string" then return nil end
    local pattern, order = Patterns.fromFormat(format)
    if not pattern then return nil end

    local captured = { text:match(pattern) }
    if captured[1] == nil then return nil end

    local result = {}
    for position, argIndex in ipairs(order) do
        result[argIndex] = captured[position]
    end
    return result
end

if ns then ns.Patterns = Patterns end
return Patterns
