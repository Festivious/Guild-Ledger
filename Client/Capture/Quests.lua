-- Quest lifecycle. Questie supplies quest definitions at read time, so only the event
-- and its moment are recorded here.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema = GBA.Schema
local episodes, buffer, questLog = ns.episodes, ns.buffer, ns.questLog

local ACTION = Schema.questAction

local function record(questID, action)
    if type(questID) ~= "number" then return end
    local values = Schema.toArray(Schema.factType.quest_event, {
        questID = questID,
        action = action,
        observerLevel = UnitLevel("player"),
    })
    buffer:add(Schema.factType.quest_event, values, episodes:current(), time())
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("QUEST_REMOVED")

frame:SetScript("OnEvent", function(_, event, a, b)
    local now = time()

    if event == "QUEST_ACCEPTED" then
        -- Classic Era passes (questLogIndex, questID); later clients pass just questID.
        local questID = tonumber(b) or tonumber(a)
        questLog:accepted(questID)
        record(questID, ACTION.accepted)

    elseif event == "QUEST_TURNED_IN" then
        local questID = tonumber(a)
        -- Claimed before the fact is recorded, because QUEST_REMOVED follows immediately
        -- and would otherwise be counted as the quest being thrown away.
        questLog:turnedIn(questID, now)
        record(questID, ACTION.turnedIn)

    elseif event == "QUEST_REMOVED" then
        local questID = tonumber(a)
        if questLog:isAbandonment(questID, now) then
            record(questID, ACTION.abandoned)
        end
    end
end)

