-- One character's hard quests: which are accepted, since when, and which are turned in. Pure, no
-- WoW API use.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 2 ("A quest's life").
-- Hard quests work like the game's own: accepted at a mailbox, kept in a quest log, turned in at the
-- mailbox they name. Counting starts at accept, so the accept time is the one thing that must never
-- move: accepting again does nothing, and only abandoning (then accepting) starts a quest over.
-- Turned in is for good - once per character.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local HardLog = {}
HardLog.__index = HardLog

local ACCEPTED, TURNED_IN = "accepted", "turnedIn"

function HardLog.new()
    return setmetatable({ quests = {} }, HardLog)
end

local function posInt(v) return type(v) == "number" and v >= 1 and v == math.floor(v) end

function HardLog:status(id)
    local row = self.quests[id]
    return row and row.state or nil
end

function HardLog:acceptedAt(id)
    local row = self.quests[id]
    return row and row.acceptedAt or nil
end

-- Returns true, or nil and why.
function HardLog:accept(id, now)
    if not posInt(id) then return nil, "not a quest" end
    local state = self:status(id)
    if state == ACCEPTED then return nil, "already in your quest log" end
    if state == TURNED_IN then return nil, "already turned in on this character" end
    self.quests[id] = { state = ACCEPTED, acceptedAt = now }
    return true
end

function HardLog:abandon(id)
    if self:status(id) ~= ACCEPTED then return nil, "not in your quest log" end
    self.quests[id] = nil
    return true
end

function HardLog:turnIn(id, now)
    if self:status(id) ~= ACCEPTED then return nil, "not in your quest log" end
    local row = self.quests[id]
    row.state, row.turnedInAt = TURNED_IN, now
    return true
end

-- The quests in progress, in id order.
function HardLog:accepted()
    local ids = {}
    for id, row in pairs(self.quests) do
        if row.state == ACCEPTED then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

function HardLog:export()
    local out = {}
    for id, row in pairs(self.quests) do
        out[id] = { state = row.state, acceptedAt = row.acceptedAt, turnedInAt = row.turnedInAt }
    end
    return out
end

-- Restores from SavedVariables, revalidating every row: the file has been on disk. A damaged row
-- costs that row only.
function HardLog:load(saved)
    self.quests = {}
    if type(saved) ~= "table" then return 0 end
    local n = 0
    for id, row in pairs(saved) do
        if posInt(id) and type(row) == "table" and (row.state == ACCEPTED or row.state == TURNED_IN) then
            self.quests[id] = {
                state = row.state,
                acceptedAt = type(row.acceptedAt) == "number" and row.acceptedAt or nil,
                turnedInAt = type(row.turnedInAt) == "number" and row.turnedInAt or nil,
            }
            n = n + 1
        end
    end
    return n
end

if ns then ns.HardLog = HardLog end
return HardLog
