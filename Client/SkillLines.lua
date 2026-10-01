-- Stable numeric ids for Classic skill lines. No WoW API use.
--
-- Classic exposes no skill-line id: CHAT_MSG_SKILL gives a localized name and
-- GetSkillLineInfo returns no identifier either. Storing the name would repeat MobInfo2's
-- mistake, where a database keyed by localized text can never be aggregated across
-- locales. So we ship our own mapping and resolve the English names.
--
-- A client in another locale falls back to storing the string. That is still recoverable,
-- because the provenance envelope records the locale, but it is the lesser outcome.
--
-- IDs ARE PERMANENT. Append new lines at the end; never renumber or reorder.
local _, ns = ...
if ns and ns.standDown then return end

local SkillLines = {}

local NAMES = {
    -- Weapons
    "Axes", "Two-Handed Axes", "Bows", "Crossbows", "Daggers", "Guns",
    "Fist Weapons", "Maces", "Two-Handed Maces", "Polearms", "Staves",
    "Swords", "Two-Handed Swords", "Thrown", "Wands", "Unarmed",
    -- Defence
    "Defense", "Block", "Dodge", "Parry",
    -- Armour
    "Cloth", "Leather", "Mail", "Plate Mail", "Shield",
    -- Primary professions
    "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism",
    "Leatherworking", "Mining", "Skinning", "Tailoring",
    -- Secondary skills
    "Cooking", "First Aid", "Fishing", "Lockpicking", "Poisons", "Riding",
    -- Languages
    "Language: Common", "Language: Orcish", "Language: Darnassian",
    "Language: Taurahe", "Language: Dwarven", "Language: Gnomish",
    "Language: Troll", "Language: Thalassian", "Language: Demonic",
    "Language: Draconic", "Language: Titan", "Language: Kalimag",
    "Language: Gutterspeak",
    -- Class skill lines. Classic surfaces the talent trees as skills, so a real Paladin
    -- session produced "Holy", "Retribution" and "Protection" with no mapping to resolve
    -- them. Names shared between classes (Holy, Protection, Restoration) take one id
    -- each; the envelope's class tells the two apart.
    "Arms", "Fury", "Protection", "Holy", "Retribution",
    "Beast Mastery", "Marksmanship", "Survival",
    "Assassination", "Combat", "Subtlety",
    "Discipline", "Shadow Magic",
    "Elemental Combat", "Enhancement", "Restoration",
    "Arcane", "Fire", "Frost",
    "Affliction", "Demonology", "Destruction",
    "Balance", "Feral Combat",
}

SkillLines.id = {}
SkillLines.name = {}

for index, name in ipairs(NAMES) do
    SkillLines.id[name] = index
    SkillLines.name[index] = name
end

-- Chat messages sometimes carry the bare language name rather than the "Language: X"
-- form, so both resolve to the same id.
local ALIASES = {
    Common = "Language: Common", Orcish = "Language: Orcish",
    Darnassian = "Language: Darnassian", Taurahe = "Language: Taurahe",
    Dwarven = "Language: Dwarven", Gnomish = "Language: Gnomish",
    Troll = "Language: Troll", Thalassian = "Language: Thalassian",
    Demonic = "Language: Demonic", Draconic = "Language: Draconic",
    Titan = "Language: Titan", Kalimag = "Language: Kalimag",
    Gutterspeak = "Language: Gutterspeak",
}

for alias, canonical in pairs(ALIASES) do
    SkillLines.id[alias] = SkillLines.id[canonical]
end

-- Returns a numeric id, or the original string when the name is not recognised. The
-- caller stores whichever came back; a string is still resolvable offline via the
-- envelope's locale, it just cannot be aggregated directly.
function SkillLines.resolve(name)
    if type(name) ~= "string" then return nil end
    return SkillLines.id[name] or name
end

function SkillLines.count()
    return #NAMES
end

if ns then ns.SkillLines = SkillLines end
return SkillLines
