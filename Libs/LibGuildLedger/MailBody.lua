-- The Send Mail body box, found the same way everywhere.
--
-- This client does not have SendMailBodyEditBox, the name every older addon uses. Its body is
-- MailEditBox, a scrolling container with the real edit box inside. Writing to the old name
-- does nothing and raises nothing, so for a while the claim flow filled in the recipient and
-- the subject and left every body empty. Found in game on 2026-09-23 with the ChannelLab test
-- addon, which wrote a 256-character key letter through MailEditBox:GetEditBox() and read it
-- back whole.
--
-- Each known shape is tried in turn, newest first. `find` takes the global table as an
-- argument so the lookup is testable outside the game.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local MailBody = {}

-- Returns the box, and a short name for how it was found; or nil and a reason.
function MailBody.find(G)
    G = G or _G
    local c = G.MailEditBox
    if type(c) == "table" then
        if type(c.GetEditBox) == "function" then
            local ok, box = pcall(c.GetEditBox, c)
            if ok and type(box) == "table" and box.SetText then return box, "MailEditBox:GetEditBox()" end
        end
        local nested = type(c.ScrollBox) == "table" and c.ScrollBox.EditBox
        if type(nested) == "table" and nested.SetText then return nested, "MailEditBox.ScrollBox.EditBox" end
        if c.SetText then return c, "MailEditBox" end
    end
    local legacy = G.SendMailBodyEditBox
    if type(legacy) == "table" and legacy.SetText then return legacy, "SendMailBodyEditBox" end
    return nil, "no mail body box on this client"
end

-- Writes the body. Returns the number of characters the box kept, or nil and a reason.
function MailBody.set(text, G)
    local box, how = MailBody.find(G)
    if not box then return nil, how end
    box:SetText(text or "")
    local kept = MailBody.get(G) or ""
    return #kept, how
end

-- Reads the body, or nil when there is no box.
function MailBody.get(G)
    local box = MailBody.find(G)
    if not box then return nil end
    if box.GetText then return box:GetText() end
    G = G or _G
    local c = G.MailEditBox
    if type(c) == "table" and c.GetInputText then return c:GetInputText() end
    return nil
end

if ns then ns.MailBody = MailBody end
return MailBody
