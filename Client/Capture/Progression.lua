-- XP gains and skill-ups. No spoke provides these: every XP addon is a display-only
-- session calculator with no API, and Skillet stores queue state with no skill-up log.
--
-- Parsing is driven by Blizzard's localized format globals rather than English literals,
-- so it works on any client. The parsers are pure and take the formats as arguments.
local _, ns = ...
if ns and ns.standDown then return end

local Patterns = (ns and ns.Patterns) or require("Patterns")

local Progression = {}

-- No Blizzard format string takes anywhere near this many arguments; it only bounds the
-- walk so a malformed one cannot spin.
Progression.MAX_ARGS = 16

-- Returns amount and source, or nil when the line is not an XP gain. `formats` is an
-- ordered list of { format, source } entries, most specific first, because the exhaustion
-- and group variants are supersets of the plain one.
--
-- The source comes from WHICH format matched: a message naming a mob is a kill, an
-- unnamed one is not. That distinction is free and was previously discarded, which made
-- a 2859-experience quest turn-in indistinguishable from a mob kill.
function Progression.parseXP(text, formats)
    for _, entry in ipairs(formats) do
        -- A bare string must be handled explicitly: strings index into the string
        -- library, so entry.format on one returns string.format rather than nil.
        local isEntry = type(entry) == "table"
        local format = isEntry and entry.format or entry
        local captured = Patterns.match(text, format)
        if captured then
            -- Walked in ARGUMENT order, ascending, never with pairs.
            --
            -- Patterns.match keys its result by argument index, and pairs over that makes
            -- no promise about order - a table with a hole in it is a hash and iterates
            -- arbitrarily. The rested formats carry several numbers, as in "you gain 45
            -- experience. (30 exp 15 bonus)", so the first number pairs happened to reach
            -- could be the bonus rather than the amount. The first DECLARED number is the
            -- one that means what we want.
            for i = 1, Progression.MAX_ARGS do
                local value = captured[i]
                if value ~= nil then
                    local amount = tonumber(value)
                    if amount then return amount, isEntry and entry.source or nil end
                end
            end
        end
    end
    return nil
end

-- Returns skillName, newValue.
function Progression.parseSkillUp(text, format)
    local captured = Patterns.match(text, format)
    if not captured then return nil end

    local name, value
    for _, raw in pairs(captured) do
        local numeric = tonumber(raw)
        if numeric then value = numeric else name = raw end
    end
    if name and value then return name, value end
    return nil
end

-- The globals worth trying, most specific first. Missing ones are skipped.
--
-- A format naming the mob means the experience came from killing it. The UNNAMED variant
-- is what quest turn-ins and everything else arrive as.
function Progression.xpFormats(globals, sources)
    sources = sources or { kill = 1, other = 2, quest = 3 }

    local candidates = {
        { "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", sources.kill },
        { "COMBATLOG_XPGAIN_EXHAUSTION1", sources.kill },
        { "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP", sources.kill },
        { "COMBATLOG_XPGAIN_EXHAUSTION2", sources.kill },
        { "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP", sources.kill },
        { "COMBATLOG_XPGAIN_EXHAUSTION4", sources.kill },
        { "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP", sources.kill },
        { "COMBATLOG_XPGAIN_EXHAUSTION5", sources.kill },
        { "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", sources.kill },
        { "COMBATLOG_XPGAIN_FIRSTPERSON", sources.kill },
        { "COMBATLOG_XPGAIN_QUEST", sources.quest },
        { "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED", sources.other },
    }

    local formats = {}
    for _, candidate in ipairs(candidates) do
        local value = globals[candidate[1]]
        if type(value) == "string" then
            formats[#formats + 1] = { format = value, source = candidate[2] }
        end
    end
    return formats
end

if ns then ns.Progression = Progression end
return Progression
