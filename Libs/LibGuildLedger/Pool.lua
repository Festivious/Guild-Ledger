-- The player's pool and archive: which recorded sessions a claim sends, and how long the rest
-- are kept. Pure, no WoW API use.
--
-- The user's decisions (docs/fix-plan.md):
--   DEC-9   a data claim sends every session in the pool, in the ticked categories
--   DEC-10  the pool is the newest sessions that fit the send limit; older ones leave it by
--           themselves, archived on the player's computer: not deleted, not sent
--   DEC-11  an archived session is kept 30 days, then deleted, unless the player marks it
--   DEC-12  every login and reload is its own session
--
-- The limit is on the packed size, which is only known by packing. Rows are counted instead,
-- at a measured size per row with room to spare (about 9 bytes a row on real data, 2026-09-29),
-- and the claim still checks the real size before anything is mailed.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Pool = {}

Pool.LIMIT = 256 * 1024       -- the send limit (Transfer.MAX_SIZE)
Pool.ROW_BYTES = 10           -- a packed row, rounded up from the 9.1-9.3 measured
Pool.FILL = 0.9               -- of the limit the pool may fill
Pool.ARCHIVE_DAYS = 30

-- How many rows the pool may hold.
function Pool.rowBudget()
    return math.floor(Pool.LIMIT * Pool.FILL / Pool.ROW_BYTES)
end

-- The sessions that leave the pool, oldest first. The pool keeps the newest sessions whose rows
-- fit the budget: the one being played is always kept, and once a session does not fit, it and
-- every older one leave, so the pool is always the most recent stretch of play.
function Pool.overflow(entries, currentID, budget)
    budget = budget or Pool.rowBudget()
    local rows, ids = {}, {}
    for _, e in ipairs(type(entries) == "table" and entries or {}) do
        local sid = e.sessionID
        if sid ~= nil then
            if not rows[sid] then rows[sid] = 0; ids[#ids + 1] = sid end
            rows[sid] = rows[sid] + 1
        end
    end
    table.sort(ids, function(a, b) return a > b end)
    local used = currentID ~= nil and rows[currentID] or 0
    local out, full = {}, false
    for _, sid in ipairs(ids) do
        if sid ~= currentID then
            if not full and used + rows[sid] <= budget then
                used = used + rows[sid]
            else
                full = true
                out[#out + 1] = sid
            end
        end
    end
    table.sort(out)
    return out
end

-- Archived sessions past their days and not marked to keep, oldest first.
-- archived: sessionID -> { archivedAt, keep, ... }
function Pool.expired(archived, now)
    local cutoff = now - Pool.ARCHIVE_DAYS * 86400
    local out = {}
    for sid, a in pairs(type(archived) == "table" and archived or {}) do
        if type(a) == "table" and not a.keep and type(a.archivedAt) == "number" and a.archivedAt < cutoff then
            out[#out + 1] = sid
        end
    end
    table.sort(out)
    return out
end

if ns then ns.Pool = Pool end
return Pool
