-- Awarding a claim at the mailbox: Send Mail filled in with the reward, addressed to the
-- player, and the award recorded only when that mail actually goes.
--
-- The reverse of the player's claim (ClaimFlow): the same MailSend.prepare fills the frame from
-- the officer's bags, and GBA.mailWatch (MailWatch.lua) records the award on THIS mail's own
-- success. A reward mail that fails is not an award, and the next mail to anyone is not one
-- either; a reward mail that went is one even if the mailbox closed before the answer came.
-- Nothing is awarded for a mail that was never sent.
--
-- Declining only records (ns.declineClaim): the officer returns any items by hand and says why
-- in their own words. Decided by the user, 2026-09-23.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Reward, Resolve = GBA.Reward, GBA.Resolve

local AwardFlow = {}
ns.AwardFlow = AwardFlow

local Mailbox, watch = GBA.Mailbox, GBA.mailWatch

-- What a reward gives, split by how it travels: items and gold go on the mail; anything else
-- (a line of text, a spell) cannot, and is the officer's to deliver by hand (docs/fix-plan.md, M6).
local function gives(reward)
    local items, copper, byHand = {}, 0, {}
    for _, give in ipairs(reward.gives or {}) do
        if give.itemID then
            items[#items + 1] = { itemID = give.itemID, quantity = give.quantity or 1 }
        elseif give.kind == Reward.entryKind.money then
            copper = copper + (give.money or 0)
        else
            byHand[#byHand + 1] = give
        end
    end
    return items, copper, byHand
end

-- Opens Send Mail with the reward for one held claim. Returns true once the mail is ready.
function AwardFlow.begin(id)
    local record = ns.officerClaims and ns.officerClaims:get(id)
    if not record then return nil, "no such claim" end
    if record.state ~= Reward.state.submitted then return nil, "that claim is already decided" end
    if not Mailbox.isOpen() then return nil, "go to a mailbox to award a claim" end
    -- Asked before the mail is filled, not after it went: afterwards the answer can only say
    -- the reward was paid twice (docs/fix-plan.md, M2).
    if not ns.officerClaims:mayClaim(record.rewardID, record.from) then
        return nil, record.from .. " was already awarded this offer; decline this claim, or requeue it for them first"
    end
    -- Its poster or a decider the poster named (DEC-4); a removed offer's claims are the
    -- poster's to settle by hand (DEC-3).
    local reward = ns.decidable and ns.decidable(record.rewardID)
    if not reward then return nil, "you do not decide that offer's claims" end

    local items, copper, byHand = gives(reward)
    local names = Resolve.live(GBA.spokes)
    local owed = #byHand > 0 and Reward.describeEntries(byHand, Resolve, names) or nil
    local body = "Your reward for: " .. reward.title
    -- Said in the mail too, so the player knows the rest is coming.
    if owed then body = body .. "\n\nAlso yours, given by hand: " .. owed end
    -- The subject is what tells this mail apart from the officer's own letters to the player.
    local subject = "Reward: " .. reward.title
    local attached, missing = ns.MailSend.prepare(record.from, subject, body, items)
    if not attached then return nil, tostring(missing) end
    if copper > 0 then ns.MailSend.attachMoney(copper) end

    watch:expect("award", {
        recipient = record.from,
        subject = subject,
        onSent = function() AwardFlow.finish(id, record.from, reward.title) end,
        onFailed = function(_, why)
            GBA.Print("|cffff4040the reward mail did not go:|r " .. tostring(why or "the game refused it")
                .. ". Nothing was awarded; fix it and press Send again.")
        end,
    })
    GBA.Print(string.format("|cff40ff40the reward for %s is ready|r: %d item(s)%s. Press Send to award it.",
        record.from, attached, copper > 0 and (" and " .. Resolve.money(copper)) or ""))
    if owed then
        GBA.Print("  |cffffcc00the mail cannot carry the rest; give it by hand:|r " .. owed)
    end
    if missing and #missing > 0 then
        local names = Resolve.live(GBA.spokes)
        for _, gap in ipairs(missing) do
            GBA.Print(string.format("  |cffffcc00%s: %s|r", Resolve.itemLink(names, gap.itemID), gap.why))
        end
        GBA.Print("  |cffffcc00fill the empty slots yourself before sending|r")
    end
    return true
end

-- Declines without a mail: recorded, signed and sent to the player.
function AwardFlow.decline(id)
    return ns.declineClaim(id)
end

-- The reward mail went: record the award, sign it and send it on.
function AwardFlow.finish(id, recipient, title)
    local ok, err = ns.awardClaim(id)
    if ok then
        GBA.Print(string.format("|cff40ff40awarded %s's claim for \"%s\"|r; they are told when online", recipient, title))
    else
        GBA.Print("|cffff4040the reward mail went, but the award was not recorded:|r " .. tostring(err))
    end
    if ns.RewardsPanel and ns.RewardsPanel.built() then ns.RewardsPanel.refresh() end
end

-- A prepared reward never sent is not an award. One already in flight is not prepared any
-- more: its answer still comes, and records it.
Mailbox.onClose(function() watch:cancel("award") end)
