-- Where one claim stands, for the claimed reward's view. Replaces the Sent tab.
--
-- A claim is two things travelling separately: the claim itself (ClaimLog, by reward) and,
-- when the offer asked for data, a locked session and its key letters (the outbox, by
-- transfer id). This joins them for one reward. The outbox forgets a session once an officer
-- has it saved and every letter is mailed, so a claim with a transfer id and no outbox entry
-- is a finished one, not a lost one.
--
--   held       locked on this computer; leaves only when the claim mail is sent
--   pending    waiting for an officer to come online
--   offered    being handed to an officer now
--   delivered  an officer has it; kept here until one says it is saved
--   saved      safe with the officers
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Reward = GBA.Reward

local STATE = {
    locking = "locking",
    held = "held until the claim mail is sent",
    pending = "waiting for an officer to come online",
    offered = "being handed to an officer",
    delivered = "delivered; kept here until an officer saves it",
    saved = "safe with the officers",
}

local STATE_WORDS = {
    [Reward.state.disputed] = "questioned by the officer",
    [Reward.state.settled] = "awarded",
    [Reward.state.declined] = "declined",
}

-- The outbox entry behind a claim, or nil once it is finished (or when no data was asked).
local function entryOf(claim)
    if not claim or not claim.transferID or not ns.Outbox then return nil end
    return ns.Outbox.entries()[claim.transferID]
end

local function lettersOf(e)
    local total, mailed = 0, 0
    for _, reader in ipairs(e.readers or {}) do
        if e.letters and e.letters[reader] then
            total = total + 1
            if e.lettersSent and e.lettersSent[reader] then mailed = mailed + 1 end
        end
    end
    return total, mailed
end

-- The claim against a reward, if this character made one.
function ns.claimFor(rewardID)
    return ns.myClaims and ns.myClaims:latest(rewardID) or nil
end

-- A claim still waiting on a decision: how far it has got (docs/fix-plan.md, DEC-3 and DEC-6).
local function waitingWords(claim)
    local offer = ns.rewardCatalog and ns.rewardCatalog:get(claim.rewardID)
    if offer and offer.retracted then return "the offer was removed, so what happens now is up to the officer" end
    if claim.saved then return "safe with the officers; waiting for a decision" end
    if claim.delivered then return "an officer has it; offered again until one saves it" end
    return "sent; waiting for an officer to hear it"
end

-- Lines describing the claim against a reward, for the view to show. Empty when unclaimed.
function ns.claimLines(rewardID)
    local claim = ns.claimFor(rewardID)
    if not claim then return {} end
    local out = {}
    out[#out + 1] = string.format("Claimed %s from %s: %s.", date("%d %b %H:%M", claim.at),
        tostring(claim.issuer and claim.issuer:match("^([^%-]+)") or claim.issuer or "?"),
        claim.state == Reward.state.submitted and waitingWords(claim) or STATE_WORDS[claim.state] or "unknown")
    -- An officer who could not take it said why (E4); it is still offered to the others.
    local refusal = claim.state == Reward.state.submitted and ns.claimRefusal and ns.claimRefusal(claim)
    if refusal then out[#out + 1] = "Refused once: " .. refusal .. "." end

    if claim.attach == Reward.attach.none or not claim.transferID then
        out[#out + 1] = "No gameplay data was sent with it."
        return out
    end

    local e = entryOf(claim)
    if not e then
        out[#out + 1] = "Your data is safe with the officers, and every key letter is mailed."
        return out
    end
    out[#out + 1] = "Your data: " .. (STATE[e.state] or tostring(e.state)) .. "."
    local total, mailed = lettersOf(e)
    if total > 0 then
        out[#out + 1] = string.format("Key letters mailed: %d of %d.", mailed, total)
    end
    if e.lastError then out[#out + 1] = tostring(e.lastError) end
    return out
end

-- What Resend can do for this claim right now: "send" (letters left to mail, or data not yet
-- saved by an officer), or nil with the reason there is nothing to resend.
function ns.claimResendable(rewardID)
    local claim = ns.claimFor(rewardID)
    if not claim then return nil, "not claimed" end
    local e = entryOf(claim)
    if not e then return nil, "nothing left to send" end
    if e.state == "held" or e.state == "locking" then return nil, "the claim mail has not gone yet" end
    return "send"
end

-- The claimed reward's Resend: offers the session to the officers again, and mails any key
-- letter still waiting (at a mailbox). Once an officer has it saved there is nothing to do.
function ns.resendClaim(rewardID)
    local can, why = ns.claimResendable(rewardID)
    if not can then return nil, why end
    ns.Outbox.sync(true)
    if ns.ClaimFlow and ns.ClaimFlow.resumeLetters then ns.ClaimFlow.resumeLetters() end
    return true
end
