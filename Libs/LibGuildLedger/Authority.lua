-- Who may do what. Pure, no WoW API use.
--
-- The one place a permission is decided. Every check that asks "may this person offer a
-- reward" or "may this client hold other players' data" comes here, so that when the rule
-- changes it changes once.
--
-- It is going to change. Two roles exist and they are not the same thing:
--
--   offer     may put a reward in front of the guild, and so receives the claims on it
--   officer   may sync and hold guild data, and runs the officer commands
--
-- The real rule is a key hierarchy. The guild master's key is the root, and the guild
-- master signs other players' keys to grant them a role. A submission then proves its own
-- authority by its signature chain, and nobody has to look anything up. That needs
-- signatures, which arrive with Stage 1 of the backbone
-- (docs/superpowers/plans/2026-09-23-phase2-backbone-prompt.md).
--
-- Until then, guild rank stands in for both roles. It is a weaker rule - rank is coarse,
-- and it cannot name one player without naming everyone at that rank - but it is
-- server-attested, which a claim written inside a payload never is. Every caller passes
-- the facts it has in `facts`, so replacing rank with a verified certificate is a change
-- to this file and not to the callers.
--
-- Unknown is never allowed. A rank that could not be read is not an officer: declining
-- to guess upward is the safe direction for a permission check, and the failure has to
-- lean toward doing less.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Reward
if ns then
    Reward = ns.Reward
else
    Reward = require("Reward")
end

local Authority = {}

-- Each role, and the name it has on the guild master's list.
Authority.role = {
    offer = "publisher",
    officer = "officer",
    reader = "reader",
    dev = "dev",
}

-- The verified role list (a Roles store), set by the game side. Nil until one exists.
Authority.store = nil

-- Whether a named character is in the guild right now: true, false, or nil when that cannot be
-- told yet (the roster not loaded). Set by the game side. The list names characters, and a name
-- on it used to keep its role after leaving the guild, until the guild master edited the list;
-- a character the roster says is not in the guild holds no role (docs/fix-plan.md, I10, G2).
Authority.membership = nil

-- Returns allowed, reason. The reason is for a person to read when they are refused.
--
-- facts: { name = character name, rankIndex = guild rank }. With a verified list, the list
-- decides by name. Without one, rank stands in, and an unknown rank is refused.
function Authority.may(role, facts)
    local kind = Authority.role[role]
    if not kind then
        return false, "unknown role " .. tostring(role)
    end
    if type(facts) ~= "table" then
        return false, "nothing known about who is asking"
    end

    local store = Authority.store
    if store and facts.name then
        local verdict = store:has(facts.name, kind)
        if verdict and Authority.membership and Authority.membership(facts.name) == false then
            return false, "not in the guild, whatever the guild master's list says"
        end
        if verdict ~= nil then
            return verdict, verdict and ("a " .. kind .. " on the guild master's list")
                or ("not a " .. kind .. " on the guild master's list")
        end
    end

    local rank = facts.rankIndex
    if type(rank) ~= "number" then
        return false, "rank unknown"
    end
    if Reward.mayOffer(rank) then
        return true, "rank " .. rank
    end
    return false, "rank " .. rank .. " is not an officer rank"
end

if ns then ns.Authority = Authority end
return Authority
