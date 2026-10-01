-- BigWigs — encounter boundaries.
--
-- Needed because Classic Era does not reliably fire ENCOUNTER_START for vanilla raids,
-- so BigWigs' own engage detection is the only dependable labelling for raid content.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end
local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local BigWigs = { name = "BigWigs" }

BigWigs.MESSAGES = { "BigWigs_OnBossEngage", "BigWigs_OnBossWin", "BigWigs_OnBossWipe" }

function BigWigs.detect(env)
    if type(env.global("BigWigsLoader")) ~= "table" then return false end
    local version = env.metadata("BigWigs", "Version")
    return true, version
end

-- No embedding required: third parties register straight on the loader's CallbackHandler.
function BigWigs.registerBossCallbacks(env, target, handler)
    local loader = env.global("BigWigsLoader")
    local register = Adapter.field(loader, "RegisterMessage")
    if type(register) ~= "function" then return nil end

    local registered = {}
    for _, message in ipairs(BigWigs.MESSAGES) do
        local ok = Adapter.safeCall(register, loader, target, message, handler)
        registered[message] = ok
    end
    return registered
end

if ns and ns.Spokes then ns.Spokes:register(BigWigs) end
return BigWigs
