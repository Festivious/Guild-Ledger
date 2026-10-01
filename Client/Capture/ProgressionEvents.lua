-- XP gains and skill-ups from chat messages, parsed via Blizzard's localized formats.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema, SkillLines = GBA.Schema, ns.SkillLines
local Progression, episodes, buffer = ns.Progression, ns.episodes, ns.buffer

local xpFormats = Progression.xpFormats(_G, Schema.xpSource)
local skillFormat = _G.ERR_SKILL_UP_SI

local function onXPGain(text)
    local amount, source = Progression.parseXP(text, xpFormats)
    if not amount then return end

    local values = Schema.toArray(Schema.factType.xp_gain, {
        amount = amount,
        source = source or Schema.xpSource.other,
        observerLevel = UnitLevel("player"),
    })
    buffer:add(Schema.factType.xp_gain, values, episodes:current(), time())
end

local function onSkillUp(text)
    if not skillFormat then return end
    local skillName, newValue = Progression.parseSkillUp(text, skillFormat)
    if not skillName then return end

    local values = Schema.toArray(Schema.factType.skill_up, {
        -- A numeric id where the name is recognised, the raw string otherwise. Storing
        -- only the localized name would make these rows unaggregatable across locales.
        skillLine = SkillLines.resolve(skillName),
        toValue = newValue,
        viaSpellID = nil,
    })
    buffer:add(Schema.factType.skill_up, values, episodes:current(), time())
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
frame:RegisterEvent("CHAT_MSG_SKILL")
frame:SetScript("OnEvent", function(_, event, text)
    if event == "CHAT_MSG_COMBAT_XP_GAIN" then
        onXPGain(text)
    else
        onSkillUp(text)
    end
end)

