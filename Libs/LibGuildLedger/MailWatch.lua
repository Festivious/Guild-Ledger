-- Which mail was that? Pure, no WoW API use.
--
-- MAIL_SEND_SUCCESS says a mail went. It does not say which one. Guild Ledger has three mails
-- whose going changes a record - the claim, a key letter, the award - and before this each of
-- them armed itself on a click of Send and took the next success as its own. A mail that failed
-- stayed armed, and the next mail to anyone at any mailbox that session completed the claim or
-- the award. Plan: docs/fix-plan.md, M1 to M3.
--
-- What the game does tell us, measured in game on 2026-09-28 (docs/fix-plan.md, INV-1):
--   * the game's own SendMail(recipient, subject, body) runs for every send, by hand or not,
--     and at that moment the frame still holds the attachments and the gold;
--   * every send ends in exactly one of MAIL_SEND_SUCCESS or MAIL_FAILED;
--   * Send stays disabled until that answer, so only one mail is ever in flight.
-- So a mail is identified at the SendMail call, by recipient and subject, and the answer that
-- follows belongs to that call and to nothing else. Syndicator's MailCache does the same.
--
-- Closing the mailbox does not cancel a mail already in flight: its answer still comes, and a
-- mail that went must still be recorded. An owner drops only its own EXPECTATION on close, which
-- this never counts as a mail.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local MailWatch = {}
MailWatch.__index = MailWatch

-- The subject box holds 64 characters; what SendMail is handed is what the box kept.
MailWatch.SUBJECT = 64

local function norm(name)
    if type(name) ~= "string" then return nil end
    name = name:match("^%s*([^%-%s]+)") or name
    return name:lower()
end

local function subjectOf(text)
    if type(text) ~= "string" then return "" end
    return text:sub(1, MailWatch.SUBJECT)
end

function MailWatch.new()
    return setmetatable({ expected = {}, order = {}, inFlight = nil }, MailWatch)
end

-- Waits for one mail. spec: { recipient, subject, onSent(mail), onFailed(mail, why) }.
-- An expectation under the same key replaces the earlier one.
function MailWatch:expect(key, spec)
    if key == nil or type(spec) ~= "table" or not norm(spec.recipient) then return nil, "an expected mail needs a recipient" end
    if not self.expected[key] then self.order[#self.order + 1] = key end
    self.expected[key] = spec
    return true
end

-- Stops waiting for a mail that was never sent. A mail already in flight is not touched.
function MailWatch:cancel(key)
    if not self.expected[key] then return false end
    self.expected[key] = nil
    for i, k in ipairs(self.order) do
        if k == key then table.remove(self.order, i); break end
    end
    return true
end

function MailWatch:expecting(key) return self.expected[key] ~= nil end

-- The key of the mail in flight, when it is one of ours.
function MailWatch:flying()
    return self.inFlight and self.inFlight.key or nil
end

-- The game's SendMail ran. mail: { recipient, subject, body, items = { {itemID, count} }, money }.
-- Returns the key it belongs to, or nil for a mail that is nobody's here.
function MailWatch:sendCalled(mail)
    mail = type(mail) == "table" and mail or {}
    local to, subject = norm(mail.recipient), subjectOf(mail.subject)
    for _, key in ipairs(self.order) do
        local spec = self.expected[key]
        if spec and norm(spec.recipient) == to and subjectOf(spec.subject) == subject then
            -- Out of the waiting list while it flies: its answer is final, and a second press of
            -- Send on the same frame is a new call that has to match again.
            self:cancel(key)
            self.inFlight = { key = key, spec = spec, mail = mail }
            return key
        end
    end
    -- Somebody else's mail. It still flies, so its answer is swallowed rather than handed to a
    -- mail that is only waiting.
    self.inFlight = { mail = mail }
    return nil
end

-- MAIL_SEND_SUCCESS. Returns the key whose mail went, or nil.
function MailWatch:succeeded()
    local flight = self.inFlight
    self.inFlight = nil
    if not (flight and flight.key) then return nil end
    if flight.spec.onSent then flight.spec.onSent(flight.mail) end
    return flight.key
end

-- MAIL_FAILED. The frame keeps what it held, so the mail is expected again: pressing Send once
-- more is the same mail. Returns the key whose mail failed, or nil.
function MailWatch:failed(why)
    local flight = self.inFlight
    self.inFlight = nil
    if not (flight and flight.key) then return nil end
    if not self.expected[flight.key] then self:expect(flight.key, flight.spec) end
    if flight.spec.onFailed then flight.spec.onFailed(flight.mail, why) end
    return flight.key
end

if ns then ns.MailWatch = MailWatch end
return MailWatch
