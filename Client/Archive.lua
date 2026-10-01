-- The player's archive: recorded sessions that have left the pool, locked with this character's
-- own key (docs/fix-plan.md, DEC-9 to DEC-12, DEC-19). Pool.lua decides what leaves; this keeps
-- it.
--
-- The pool is the capture buffer, and a data claim sends every session in it (Submit.gather).
-- At login the sessions past the send limit are archived: packed, then locked with a key only
-- this character's save file holds. Locking is the only way into the archive, and a locked
-- session is not read by anything: not the analytics, not guild-quest progress, not a claim. It
-- is listed on the sessions page as archived. Unlocking it puts its rows back in the pool, where
-- it can be viewed again, and where a data claim sends it again the normal way (DEC-19). An
-- archived session is deleted after 30 days unless kept.
--
-- The personal key is not an officer's key and never leaves this computer: it locks what the
-- player set aside, nothing more. Sealing and opening run a few blocks a frame (Crypto's jobs),
-- because either done whole on an hour of play would stop the addon.
--
-- A recording saved in an older fact layout cannot be read by this build. It used to be
-- skipped at load and overwritten at the next logout, every session gone at once (NEW-4). It is
-- set aside as it was and deleted after the same 30 days.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Pool, Codec, Schema, Crypto = GBA.Pool, GBA.Codec, GBA.Schema, GBA.Crypto
local LibDeflate = LibStub("LibDeflate", true)

local Archive = {}
ns.Archive = Archive

-- sessionID -> { data, locked, rows, first, last, archivedAt, keep, fields }. data is the sealed
-- session, print-encoded because saved variables are text; rows, first and last stay readable
-- so the sessions page can say what each one is without unlocking it.
local archived = {}
local setAside = nil    -- { fields, entries, since }: a recording in an older layout (NEW-4)
local keyHex = nil      -- this character's own archive key
local busy = {}         -- sessionID -> true while it is being locked or unlocked

local DAYS = Pool.ARCHIVE_DAYS * 86400

local function key()
    if not keyHex then keyHex = Crypto.toHex(GBA.Net.random(32)) end
    return Crypto.fromHex(keyHex)
end

function Archive.load(saved, aside, savedKey)
    archived = {}
    for sid, a in pairs(type(saved) == "table" and saved or {}) do
        if type(a) == "table" and type(a.data) == "string" and type(a.archivedAt) == "number" then
            archived[sid] = a
        end
    end
    if type(aside) == "table" and type(aside.entries) == "table" and type(aside.since) == "number" then
        setAside = aside
    end
    if type(savedKey) == "string" and #savedKey == 64 and not savedKey:find("[^%x]") then keyHex = savedKey end
end

function Archive.export()
    return archived, setAside, keyHex
end

-- A recording this build cannot read: kept as it is for 30 days, from the first time it was
-- set aside.
function Archive.setAside(entries, fields, now)
    if type(entries) ~= "table" or #entries == 0 then return end
    setAside = { fields = fields, entries = entries, since = setAside and setAside.since or now }
end

-- The archived sessions, newest first: { sessionID, rows, first, last, archivedAt, keep, busy }.
function Archive.list()
    local out = {}
    for sid, a in pairs(archived) do
        out[#out + 1] = { sessionID = sid, rows = a.rows, first = a.first, last = a.last,
            archivedAt = a.archivedAt, keep = a.keep == true, busy = busy[sid] == true }
    end
    table.sort(out, function(x, y) return x.sessionID > y.sessionID end)
    return out
end

function Archive.isArchived(sid) return archived[sid] ~= nil end

-- The player marks an archived session to keep past its 30 days, or lets it go again.
function Archive.keep(sid, keep)
    local a = archived[sid]
    if not a then return false end
    a.keep = keep ~= false or nil
    return true
end

-- Every row in the pool, handed to fn one at a time: what guild-quest progress counts. Locked
-- sessions are not read (DEC-19).
function ns.eachRecord(fn)
    for _, e in ipairs(ns.buffer and ns.buffer.entries or {}) do fn(e) end
end

-- One session's rows from the pool; an archived session has none until it is unlocked.
function ns.sessionRecords(sid)
    local out = {}
    for _, e in ipairs(ns.buffer and ns.buffer.entries or {}) do
        if e.sessionID == sid then out[#out + 1] = e end
    end
    return out
end

-- Locks one session out of the pool into the archive. done(ok) once sealed and moved.
local function lockSession(sid, now, done)
    local buffer = ns.buffer
    local rows, first, last = {}, nil, nil
    for _, e in ipairs(buffer.entries) do
        if e.sessionID == sid then
            rows[#rows + 1] = e
            local t = e.ts
            if type(t) == "number" then
                first = first and math.min(first, t) or t
                last = last and math.max(last, t) or t
            end
        end
    end
    if #rows == 0 or not LibDeflate then return done(false) end
    local ok, packed = pcall(Codec.pack, { fields = Schema.FIELDS_VERSION, entries = rows })
    if not ok or not packed then return done(false) end
    busy[sid] = true
    Crypto.sealRawAsync(key(), packed, GBA.Net.random(Crypto.NONCE_BYTES), function(sealed)
        busy[sid] = nil
        archived[sid] = { data = LibDeflate:EncodeForPrint(sealed), locked = true, rows = #rows,
            first = first, last = last, archivedAt = now, fields = Schema.FIELDS_VERSION }
        buffer:removeSession(sid)
        done(true)
    end)
end

-- Unlocks an archived session and puts its rows back in the pool (DEC-19): it can be viewed
-- again, and a data claim sends it again the normal way. done(ok, why).
function Archive.unlock(sid, done)
    done = done or function() end
    local a = archived[sid]
    if not a then return done(false, "that session is not archived") end
    if busy[sid] then return done(false, "that session is being locked or unlocked") end
    if a.fields ~= Schema.FIELDS_VERSION then
        return done(false, "archived in an older layout this version cannot read")
    end
    local function restore(payload)
        local rows = type(payload) == "table" and type(payload.entries) == "table" and payload.entries
        if not rows then return done(false, "the session could not be read") end
        archived[sid] = nil
        ns.buffer:restoreRows(rows)
        done(true)
    end
    if not a.locked then
        -- Archived by an earlier build, packed but not locked.
        return restore(Codec.decode(a.data))
    end
    local sealed = LibDeflate and LibDeflate:DecodeForPrint(a.data)
    if not sealed then return done(false, "the archived session is damaged") end
    busy[sid] = true
    Crypto.openRawAsync(key(), sealed, function(packed, err)
        busy[sid] = nil
        if not packed then return done(false, "it did not unlock: " .. tostring(err)) end
        restore(Codec.unpack(packed))
    end)
end

-- Locks the sessions past the pool's limit into the archive, one at a time, each sealed over a
-- few frames so a long history never stalls the game, and deletes archived ones past their
-- days. done(locked) at the end.
function Archive.rebalance(done)
    local now = GBA.now()
    for _, sid in ipairs(Pool.expired(archived, now)) do archived[sid] = nil end
    if setAside and now - setAside.since > DAYS then setAside = nil end

    local buffer = ns.buffer
    if not buffer then return done and done(0) end
    local current = ns.episodes and ns.episodes:current().sessionID
    local over = Pool.overflow(buffer.entries, current)
    local i, locked = 0, 0
    local function nextOne()
        i = i + 1
        local sid = over[i]
        if not sid then return done and done(locked) end
        lockSession(sid, now, function(ok)
            if ok then locked = locked + 1 end
            C_Timer.After(0, nextOne)
        end)
    end
    nextOne()
end

-- After login, once the capture is running. Quietly: the player notices nothing but a claim
-- that stays small.
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    C_Timer.After(30, function() Archive.rebalance() end)
end)
