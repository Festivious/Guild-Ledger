-- The mailbox, as the game reports it: open or closed, and which mail went.
--
-- One place for both, because both were wrong in three places.
--
-- Closing. MAIL_CLOSED did not fire on this client in the mail probe of 2026-09-28: the mailbox
-- was shut several times with the event registered and it never came (docs/fix-plan.md, NEW-5).
-- DataStore_Mails, installed and working here, sees the close as
-- PLAYER_INTERACTION_MANAGER_FRAME_HIDE for the mail interaction instead. Both are listened
-- for, and the close is reported once per visit whichever arrives, so a client that does fire
-- MAIL_CLOSED loses nothing.
--
-- Sending. Every send runs the game's SendMail, whether the player pressed Send or the addon
-- posted for them, and ends in MAIL_SEND_SUCCESS or MAIL_FAILED. The hook reads the frame at
-- that call, while it still holds the attachments, and GBA.mailWatch (MailWatch.lua) decides
-- whose mail it was.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if not ns or not ns.loading then return end

local Mailbox = {}
ns.Mailbox = Mailbox
ns.mailWatch = ns.MailWatch.new()

local open = false
local openers, closers = {}, {}

function Mailbox.isOpen() return open end

-- fn() runs on every open and every close. Handlers are told once per visit.
function Mailbox.onOpen(fn) openers[#openers + 1] = fn end
function Mailbox.onClose(fn) closers[#closers + 1] = fn end

local function tell(list)
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn)
        if not ok and ns.recordError then ns.recordError(err) end
    end
end

local function opened()
    if open then return end
    open = true
    tell(openers)
end

local function closed()
    if not open then return end
    open = false
    tell(closers)
end

-- What the Send Mail frame holds right now. Read at the SendMail call, before the game clears it.
local function snapshot(recipient, subject, body)
    local items = {}
    for slot = 1, _G.ATTACHMENTS_MAX_SEND or 12 do
        local ok, name, itemID, _, count = pcall(GetSendMailItem, slot)
        if ok and name and itemID then items[#items + 1] = { itemID = itemID, count = count or 1 } end
    end
    local money = 0
    if type(GetSendMailMoney) == "function" then
        local ok, copper = pcall(GetSendMailMoney)
        if ok and type(copper) == "number" then money = copper end
    end
    return { recipient = recipient, subject = subject, body = body, items = items, money = money }
end

local hooked = false
local function hookSend()
    if hooked or type(SendMail) ~= "function" then return end
    hooked = true
    hooksecurefunc("SendMail", function(recipient, subject, body)
        ns.mailWatch:sendCalled(snapshot(recipient, subject, body))
    end)
end

-- The mail interaction's type, where this client has the interaction manager.
local MAIL_TYPE = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.MailInfo

local frame = CreateFrame("Frame")
for _, event in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
    pcall(frame.RegisterEvent, frame, event)
end
hookSend()

-- The reason a send failed is the red error line the game shows just before MAIL_FAILED.
local lastError = nil

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "MAIL_SHOW" then
        hookSend()
        opened()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if MAIL_TYPE and arg1 == MAIL_TYPE then hookSend(); opened() end
    elseif event == "MAIL_CLOSED" then
        closed()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if MAIL_TYPE and arg1 == MAIL_TYPE then closed() end
    elseif event == "UI_ERROR_MESSAGE" then
        lastError = arg2
    elseif event == "MAIL_SEND_SUCCESS" then
        lastError = nil
        ns.mailWatch:succeeded()
    elseif event == "MAIL_FAILED" then
        local why = lastError
        lastError = nil
        ns.mailWatch:failed(why)
    end
end)
pcall(frame.RegisterEvent, frame, "UI_ERROR_MESSAGE")
