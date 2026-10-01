-- Group composition tracking. Pure, no WoW API use.
--
-- Records WHAT the group was, never WHO: numeric class, level and role. A five-mage group
-- and a tank-healer-three-DPS group are different data and must not both be "groupSize 5",
-- but nothing personally identifying about other players needs to leave the client to
-- tell them apart.
--
-- Solo counts as a group of one, so every fact is sliceable by composition rather than
-- only the grouped ones.
local _, ns = ...
if ns and ns.standDown then return end

local Roster = {}
Roster.__index = Roster

function Roster.new()
    return setmetatable({ groupID = nil, nextID = 1, members = {}, signature = nil }, Roster)
end

-- Order must not matter: the same five players in a different party order are the same
-- composition, so members are sorted before the signature is built.
local function signatureOf(members)
    local parts = {}
    for i, member in ipairs(members) do
        parts[i] = string.format("%d/%d/%d",
            member.classID or 0, member.level or 0, member.role or 0)
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

Roster.signatureOf = signatureOf

local function copyMembers(members)
    local out = {}
    for i, member in ipairs(members) do
        out[i] = { classID = member.classID, level = member.level, role = member.role }
    end
    return out
end

-- Returns groupID, changed. A new id is issued only when the composition actually
-- differs, so a roster event that reports the same group does not churn the chain.
function Roster:update(members)
    members = members or {}
    local signature = signatureOf(members)

    if self.groupID and signature == self.signature then
        return self.groupID, false
    end

    self.groupID = self.nextID
    self.nextID = self.nextID + 1
    self.signature = signature
    self.members = copyMembers(members)
    return self.groupID, true
end

function Roster:current()
    return { groupID = self.groupID, members = copyMembers(self.members) }
end

function Roster:size()
    return #self.members
end

if ns then ns.Roster = Roster end
return Roster
