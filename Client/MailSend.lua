-- Filling in the mail that goes with a claim.
--
-- It does send it, once the player has confirmed. The confirmation is the safeguard
-- rather than making them drive the mailbox by hand: items leaving somebody's bags cannot
-- be undone, so what is going is listed in full and agreed to once, and then the addon
-- does the rest without making them re-do work they already did in the claim panel.
--
-- The accept happens inside a real button click, which is also what keeps this on the
-- right side of whatever the client requires of an addon posting mail.
--
-- This is the other half of the design's bargain: the mail carries the PROOF, the
-- transport carries the story. Holding the items IS the evidence, and no telemetry is
-- needed to verify an outcome the officer is literally holding.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local MailSend = {}
ns.MailSend = MailSend

-- Classic's mailbox takes twelve attachments.
MailSend.MAX_ATTACHMENTS = 12

-- One pick from the plan, carried out against the bags as they are RIGHT NOW rather than as
-- they were when the plan was made. Attaching moves items, a split leaves a remainder in
-- the same slot, and the player can be dragging things around while this runs; so every
-- pick re-reads its slot and refuses if what it finds is not what it planned for. Sending
-- the wrong item is the one outcome worse than sending nothing.
local function take(pick)
    local liveID, liveCount = GBA.Bags.slotItem(pick.bag, pick.slot)
    if liveID ~= pick.itemID then
        return false, "that bag slot changed while the mail was being filled"
    end
    liveCount = liveCount or 0
    if liveCount < pick.count then return false, "that stack is smaller than it was" end

    if liveCount > pick.count then
        -- A partial stack has to be split, or attaching takes the whole thing. Somebody who
        -- asked for twenty linen should not lose forty.
        local split = (C_Container and C_Container.SplitContainerItem) or SplitContainerItem
        if not split then return false, "this client cannot split a stack" end
        return pcall(split, pick.bag, pick.slot, pick.count)
    end

    local pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
    if not pickup then return false, "this client cannot pick up an item" end
    return pcall(pickup, pick.bag, pick.slot)
end

-- What each entry asked for, summed, so one item wanted twice is one shortfall rather than
-- two half-answers.
local function wantedTotals(entries)
    local totals, order = {}, {}
    for _, entry in ipairs(entries or {}) do
        if entry.itemID then
            if not totals[entry.itemID] then order[#order + 1] = entry.itemID end
            totals[entry.itemID] = (totals[entry.itemID] or 0) + (entry.quantity or 1)
        end
    end
    return totals, order
end

-- Why an entry could not be planned, in words the player can act on.
local function planFailure(gap)
    if gap.reason == ns.Stacks.reason.noSlots then
        return string.format("would need %d attachment slots and there are not that many left",
            gap.needs or 1)
    end
    if gap.have <= 0 then return "not in your bags" end
    return string.format("you have %d of the %d it asks for", gap.have, gap.want)
end

-- Mail goes to a character, not to Name-Realm. The corpus qualifies everything by realm so
-- two people with one name stay distinct; the mailbox does not want that half.
function MailSend.recipientOf(observerKey)
    if type(observerKey) ~= "string" then return nil end
    return (observerKey:match("^([^%-]+)")) or observerKey
end

-- Fills in the mail. Returns attached count, plus a list of what could not be found.
function MailSend.prepare(recipient, subject, body, entries)
    if not _G.MailFrame or not _G.MailFrame:IsShown() then
        return nil, "open a mailbox first"
    end
    if type(SendMailNameEditBox) ~= "table" then
        return nil, "this client's send-mail frame is not where expected"
    end

    -- Blizzard's own tab switch, so the frame sets itself up the way it expects to be.
    if type(MailFrameTab_OnClick) == "function" then
        pcall(MailFrameTab_OnClick, nil, 2)
    end

    if ClearSendMail then pcall(ClearSendMail) end

    SendMailNameEditBox:SetText(recipient or "")
    if SendMailSubjectEditBox then
        SendMailSubjectEditBox:SetText((subject or ""):sub(1, 64))
    end
    -- Through GBA.MailBody: this client's body box is MailEditBox, and writing the old
    -- SendMailBodyEditBox name silently left every body empty.
    if body then
        local kept, how = GBA.MailBody.set(body)
        if not kept then return nil, "could not write the mail body: " .. tostring(how) end
    end

    -- Twenty linen is twenty linen whether the bags hold it as one stack, as two, or as
    -- part of a forty. Working out which bag slots add up to what each entry asks for is
    -- arithmetic, and it lives in Core where it is tested; this function only carries the
    -- answer out.
    local plan, gaps = ns.Stacks.plan(entries, GBA.Bags.snapshot(), MailSend.MAX_ATTACHMENTS)

    local attached, missing = 0, {}
    local refused = {}
    for _, gap in ipairs(gaps) do
        refused[gap.itemID] = true
        missing[#missing + 1] = { itemID = gap.itemID, why = planFailure(gap) }
    end

    -- An entry that could not be covered in full sends NOTHING, so the plan never holds a
    -- part of one. Half a hand-in reads as a completed claim to whoever opens the mail, and
    -- it is the officer who then has to work out that it was short.
    local carried = {}
    for _, pick in ipairs(plan) do
        local ok, err = take(pick)
        -- A client without CursorHasItem is taken at its word; one with it is asked,
        -- because a pick-up that quietly did nothing would otherwise count as attached.
        local holding = (type(CursorHasItem) ~= "function") or CursorHasItem()
        if ok and holding and ClickSendMailItemButton then
            pcall(ClickSendMailItemButton)
            attached = attached + 1
            carried[pick.itemID] = (carried[pick.itemID] or 0) + pick.count
        else
            -- Never leave an item on the cursor: it would be dropped into whatever the
            -- player clicks next.
            if ClearCursor then pcall(ClearCursor) end
            if not refused[pick.itemID] then
                refused[pick.itemID] = true
                missing[#missing + 1] = {
                    itemID = pick.itemID,
                    why = (ok and "could not attach") or err or "could not attach",
                }
            end
        end
    end

    -- The last word belongs to arithmetic rather than to whether the calls appeared to
    -- work: what went on the mail is compared against what was asked for, item by item.
    -- In the order the offer lists them: pairs() would report the same two gaps in a
    -- different order on every run, which reads like a different failure each time.
    local wanted, order = wantedTotals(entries)
    for _, itemID in ipairs(order) do
        local want = wanted[itemID]
        if not refused[itemID] and (carried[itemID] or 0) < want then
            missing[#missing + 1] = {
                itemID = itemID,
                why = string.format("only %d of %d went on the mail",
                    carried[itemID] or 0, want),
            }
        end
    end

    return attached, missing
end

-- Everything the entries ask for is in the bags and would fit on one mail. The claim panel
-- asks this before it offers the button, so "you are fifteen linen short" is said while the
-- items are still in the player's bags rather than after half of them have gone.
function MailSend.canCover(entries)
    local _, gaps = ns.Stacks.plan(entries, GBA.Bags.snapshot(), MailSend.MAX_ATTACHMENTS)
    if #gaps == 0 then return true end

    local reasons = {}
    for _, gap in ipairs(gaps) do
        reasons[#reasons + 1] = { itemID = gap.itemID, why = planFailure(gap) }
    end
    return false, reasons
end

-- Gold goes on the mail itself rather than as an attachment.
function MailSend.attachMoney(copper)
    if type(copper) ~= "number" or copper <= 0 then return 0 end
    if type(SetSendMailMoney) ~= "function" then return 0, "this client cannot attach money" end
    local ok = pcall(SetSendMailMoney, copper)
    return ok and copper or 0
end

-- Posts what prepare() filled in. Returns true, or nil and a reason.
function MailSend.post(recipient, subject, body)
    if type(SendMail) ~= "function" then return nil, "this client cannot send mail" end
    if not recipient or recipient == "" then return nil, "no recipient" end

    local ok, err = pcall(SendMail, recipient, (subject or ""):sub(1, 64), body or "")
    if not ok then return nil, tostring(err) end
    return true
end
