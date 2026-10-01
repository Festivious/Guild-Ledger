-- Reads the live group roster and records composition changes.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Schema = GBA.Schema
local roster, episodes, buffer = ns.roster, ns.episodes, ns.buffer

local ROLE = {
    TANK = Schema.role.tank,
    HEALER = Schema.role.healer,
    DAMAGER = Schema.role.damage,
}

local function roleOf(unit)
    if not UnitGroupRolesAssigned then return Schema.role.unknown end
    local ok, assigned = pcall(UnitGroupRolesAssigned, unit)
    if not ok then return Schema.role.unknown end
    return ROLE[assigned] or Schema.role.unknown
end

local function memberFor(unit)
    if not UnitExists(unit) then return nil end
    local _, _, classID = UnitClass(unit)
    return {
        classID = classID or 0,
        level = UnitLevel(unit) or 0,
        role = roleOf(unit),
    }
end

-- Solo is a group of one: the player alone is still a composition worth recording.
local function readRoster()
    local members = { memberFor("player") }
    if not members[1] then return {} end

    local count = GetNumGroupMembers and GetNumGroupMembers() or 0
    if count <= 1 then return members end

    local prefix = IsInRaid and IsInRaid() and "raid" or "party"
    local others = (prefix == "raid") and count or (count - 1)

    for i = 1, others do
        local member = memberFor(prefix .. i)
        -- In a raid the player appears in the roster too; skip the duplicate.
        if member and not (prefix == "raid" and UnitIsUnit(prefix .. i, "player")) then
            members[#members + 1] = member
        end
    end
    return members
end

local function refresh()
    local members = readRoster()
    local groupID, changed = roster:update(members)
    episodes:setGroup(groupID)
    if not changed then return end

    -- One row per member. They share the chain's groupID, so every other fact recorded
    -- from here on can be joined back to this composition.
    local chain, now = episodes:current(), time()
    for _, member in ipairs(members) do
        local values = Schema.toArray(Schema.factType.group_member, member)
        buffer:add(Schema.factType.group_member, values, chain, now)
    end
end

ns.refreshRoster = refresh

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:SetScript("OnEvent", refresh)

