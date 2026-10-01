-- Questie — static game data: NPCs, quests, items, and Wowhead-derived drop baselines.
--
-- Only Public/ is covered by Questie's stability promise. Everything used here is reached
-- through QuestieLoader and is explicitly version-fragile, hence the defensive wrapping.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local Questie = { name = "Questie" }

local function module(env, moduleName)
    local loader = env.global("QuestieLoader")
    local import = Adapter.field(loader, "ImportModule")
    if type(import) ~= "function" then return nil end
    return Adapter.tryCall(import, loader, moduleName)
end

function Questie.detect(env)
    if type(env.global("QuestieLoader")) ~= "table" then return false end
    local version = env.metadata("Questie", "Version")
    return true, version
end

function Questie.getNPC(env, npcID)
    local db = module(env, "QuestieDB")
    local fn = Adapter.field(db, "GetNPC")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, db, npcID)
end

function Questie.getQuest(env, questID)
    local db = module(env, "QuestieDB")
    local fn = Adapter.field(db, "GetQuest")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, db, questID)
end

-- Wowhead-derived baseline, for comparing against what we actually observe.
function Questie.getDropRate(env, itemID, npcID)
    local db = module(env, "QuestieDB")
    local fn = Adapter.field(db, "GetItemDroprate")
    if type(fn) ~= "function" then return nil end
    return Adapter.tryCall(fn, db, itemID, npcID)
end

if ns and ns.Spokes then ns.Spokes:register(Questie) end
return Questie
