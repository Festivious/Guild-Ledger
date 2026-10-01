-- Claiming: the turn-in, and the one place in this addon where something irreversible
-- happens.
--
-- The shape is the game's own. Claiming a reward is completing a quest and handing it back
-- to the quest giver, and the hand-back here is a piece of mail, so Claim does not open a
-- submission screen of our own - it drops the player into Blizzard's actual Send Mail tab
-- with the offer's items already in the slots, addressed to the officer who wrote it, and
-- then gets out of the way. The player presses Send, the same Send they press for every
-- other piece of mail in the game.
--
-- That matters beyond looking familiar. The items only leave on a real click of a real
-- button in the default UI, and what is in the slots is visible in the frame the player
-- already trusts, rather than described to them by us.
--
-- The claim itself - the record, and whatever telemetry the offer asked for - is sent only
-- after THIS mail actually goes. GBA.mailWatch (MailWatch.lua) ties the game's answer to the
-- SendMail call it belongs to, so a failed claim mail followed by any other mail is not a
-- claim, and a claim mail that went is one even if the mailbox closed before the answer came.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Reward, Resolve, Keys = GBA.Reward, GBA.Resolve, GBA.Keys

local Flow = {}
ns.ClaimFlow = Flow

-- Spelled this way because a backslash escape does not survive every editing path.
local NEWLINE = string.char(10)

local state = { reward = nil, sessionID = nil }

-- A claim waiting on the player: the mail has been filled in, and Send not yet pressed.
local pending = nil

local Mailbox, watch = GBA.Mailbox, GBA.mailWatch

-- Whether the mailbox is open right now. Guild quests are accepted and turned in only there.
function ns.isAtMailbox() return Mailbox.isOpen() end

-- Letters mailed one per Send after the claim itself: key letters for a reward's extra readers,
-- then a letter to each of its other deciders (docs/fix-plan.md, DEC-5).
local letterQueue = nil      -- { list = { { kind, to, ... } }, i }

-- Subjects the addon writes, so each mail can be told apart from the player's own letters.
local function letterSubject(sid) return "Session key " .. sid end
local function claimLetterSubject(title) return ("Claim: " .. tostring(title)):sub(1, 64) end

-- What this character is, for gating and for attribution.
function ns.actor()
    local _, class = UnitClass("player")
    local _, race = UnitRace("player")

    -- The rank the game reports, the one the officer's addon judges a claim's audience by
    -- (GBA.rosterMember): one source on both sides, or a player shown an offer as theirs would
    -- have the claim declined as outside its audience (docs/fix-plan.md, T5). GRM is asked only
    -- while the game has not answered yet, and its 99 means it does not know either. An unknown
    -- rank locks a rank-gated offer rather than opening it.
    local rankIndex = GBA.ownRank()
    if type(rankIndex) ~= "number" and ns.blizzardRankOf then
        rankIndex = ns.blizzardRankOf(UnitName("player"))
    end
    if type(rankIndex) ~= "number" then
        local _, grm = GBA.spokes:call("GRM", "getRank", UnitName("player"))
        if type(grm) == "number" and grm < 99 then rankIndex = grm end
    end

    return {
        -- For an offer's audience (Reward.inAudience): named players are matched by this.
        name = UnitName("player"),
        level = UnitLevel("player"),
        class = class,
        race = race,
        rankIndex = type(rankIndex) == "number" and rankIndex or nil,
        now = GBA.now(),
    }
end

-- Selection -------------------------------------------------------------------

function Flow.select(reward)
    -- A session chosen for one offer is not a session chosen for the next one.
    if state.reward ~= reward then state.sessionID = nil end
    state.reward = reward
end

function Flow.setSession(id) state.sessionID = id end
function Flow.session() return state.sessionID end

-- What the offer asks the player to post. Items only: gold rides on the mail itself
-- rather than in an attachment slot, which is how the game does it.
local function wantedItems(reward)
    local entries = {}
    for _, want in ipairs(reward.wants or {}) do
        if want.itemID then
            entries[#entries + 1] = { itemID = want.itemID, quantity = want.quantity or 1 }
        end
    end
    return entries
end

local function wantedMoney(reward)
    local copper = 0
    for _, want in ipairs(reward.wants or {}) do
        if want.kind == Reward.entryKind.money then copper = copper + (want.money or 0) end
    end
    return copper
end

-- The claim exactly as it would be sent right now. The consent panel is drawn from this
-- rather than written beside it, so what the player is told cannot drift from what the
-- button does.
function Flow.preview(reward)
    reward = reward or state.reward
    if not reward then return nil end

    return Reward.claim({
        rewardID = reward.id,
        from = ns.observerKey and ns.observerKey() or "?",
        sending = wantedItems(reward),
        attach = reward.attach,
        sessionID = state.sessionID,
    })
end

-- Claiming --------------------------------------------------------------------

local function claimAttachment(reward)
    local attach = reward.attach or Reward.attach.none
    if attach == Reward.attach.session and not state.sessionID then return Reward.attach.none end
    return attach
end

-- The note a player typed, without the key letters the addon put around it.
local function stripLetters(note)
    if type(note) ~= "string" then return note end
    for _, block in ipairs(Keys.findLetters(note)) do
        local s, e = note:find(block, 1, true)
        if s then note = note:sub(1, s - 1) .. note:sub(e + 1) end
    end
    note = note:gsub("Session key for session %x+ from [^\n]*", ""):gsub("Claiming: [^\n]*", "")
    note = note:match("^%s*(.-)%s*$")
    return note ~= "" and note or nil
end

local fillClaimMail

local function recipientOf(reward)
    return ns.MailSend and ns.MailSend.recipientOf(reward.issuer) or nil
end

-- Posts nothing and sends nothing: fills in Blizzard's Send Mail tab and hands the player
-- the frame. Returns true if the hand-off happened.
function Flow.begin(reward)
    reward = reward or state.reward
    if not reward then return GBA.Print("pick a reward first") end

    if not Mailbox.isOpen() then
        GBA.Print("|cffffcc00go to a mailbox to claim a reward|r")
        GBA.Print("  what you hand in goes by mail, so the claim is made there")
        return false
    end

    -- One claim per offer per character, unless an officer requeued it. Checked before
    -- anything is locked or mailed.
    if ns.myClaims and ns.myClaims:blocks(reward.id) then
        GBA.Print("|cffffcc00you have already claimed \"" .. reward.title .. "\"|r")
        return false
    end

    -- A poster who left the guild can decide nothing, so nothing is mailed to them (G2).
    if GBA.inGuild(reward.issuer) == false then
        GBA.Print("|cffffcc00\"" .. reward.title .. "\" was posted by someone no longer in the guild|r")
        return false
    end

    local unlocked, unmet = Reward.gate(reward, ns.actor())
    if not unlocked then
        GBA.Print("|cffff4040you cannot claim \"" .. reward.title .. "\" yet|r")
        for _, why in ipairs(unmet) do GBA.Print("  " .. why) end
        return false
    end

    local items = wantedItems(reward)
    local copper = wantedMoney(reward)

    -- Cannot happen through Reward.new, which caps wants at the send limit. Checked anyway
    -- because a cap that is only enforced where it was written is a cap that moves.
    if #items > Reward.MAX_WANTS then
        GBA.Print(string.format(
            "|cffff4040\"%s\" asks for %d items and one mail carries %d|r",
            reward.title, #items, Reward.MAX_WANTS))
        GBA.Print("  ask the officer to split it into two offers")
        return false
    end

    -- Nothing physical to hand over, so there is no mail to send and the claim is the
    -- whole of it. Confirmed here, because this is the only path where pressing Claim is
    -- itself the irreversible act.
    -- Data travels only with a key letter, and a letter is a mail, so an offer that asks
    -- for data always goes through the mailbox, even when it asks for no items.
    local attach = claimAttachment(reward)
    if #items == 0 and copper == 0 and attach == Reward.attach.none then
        return Flow.confirmBare(reward)
    end

    local recipient = recipientOf(reward)
    if not recipient then return GBA.Print("that reward has no issuer to post to") end

    -- Asked BEFORE the mail is filled in, while everything is still in the player's bags.
    -- The same arithmetic runs again inside prepare, which is what actually guards the
    -- send; this one exists so that being fifteen linen short reads as "you are fifteen
    -- linen short" rather than as a half-filled mail the player has to unpick.
    local enough, short = ns.MailSend.canCover(items)
    if not enough then
        GBA.Print("|cffff4040you cannot cover \"" .. reward.title .. "\" yet|r")
        local names = Resolve.live(GBA.spokes)
        for _, gap in ipairs(short) do
            GBA.Print("  " .. Resolve.itemLink(names, gap.itemID) .. ": " .. gap.why)
        end
        return false
    end

    if attach ~= Reward.attach.none then
        return Flow.lockThenFill(reward, items, copper, recipient, attach)
    end
    return fillClaimMail(reward, items, copper, recipient)
end

-- Fills Blizzard's Send Mail tab for a claim: the items, the gold, and - when the offer asks
-- for data - the key letter for its issuer in the body.
fillClaimMail = function(reward, items, copper, recipient, transferID, letter)
    local body = "Claiming: " .. reward.title
    if letter then body = body .. NEWLINE .. NEWLINE .. letter.body end
    local attached, missing = ns.MailSend.prepare(recipient, reward.title, body, items)
    if not attached then
        return GBA.Print("|cffff4040" .. tostring(missing) .. "|r")
    end

    if copper > 0 then ns.MailSend.attachMoney(copper) end

    local claim = {
        reward = reward,
        recipient = recipient,
        items = items,
        copper = copper,
        sessionID = state.sessionID,
        transferID = transferID,
        at = GBA.now(),
    }
    pending = claim
    -- Completed by this mail going, and by nothing else. A mail that fails stays expected,
    -- because the frame keeps it and Send can be pressed again.
    watch:expect("claim", {
        recipient = recipient,
        subject = reward.title,
        onSent = function(mail) Flow.finish(claim, mail) end,
        onFailed = function(_, why)
            GBA.Print("|cffff4040the claim mail did not go:|r " .. tostring(why or "the game refused it")
                .. ". Nothing was claimed; fix it and press Send again.")
        end,
    })

    GBA.Print(string.format("|cff40ff40%s is ready to send to %s|r: %d item(s)%s",
        reward.title, recipient, attached,
        copper > 0 and (" and " .. Resolve.money(copper)) or ""))

    if missing and #missing > 0 then
        local names = Resolve.live(GBA.spokes)
        for _, gap in ipairs(missing) do
            GBA.Print(string.format("  |cffffcc00%s: %s|r",
                Resolve.itemLink(names, gap.itemID), gap.why))
        end
        GBA.Print("  |cffffcc00fill the empty slots yourself before sending|r")
    end

    if ns.config.autoSend then
        return Flow.autoSend()
    end

    GBA.Print("  press |cff00d1ffSend|r on the mail to complete the claim")
    return true
end

-- Locks the data the offer asks for, then fills the mail with its key letter.
--
-- Pressing Claim locks it on this computer and nothing more: the session is held until the
-- player presses Send, and deleted if they walk away instead. Send is the consent.
function Flow.lockThenFill(reward, items, copper, recipient, attach)
    if not (ns.Outbox and ns.Submit) then return GBA.Print("|cffff4040the secure transport is not loaded|r") end
    local readers = Reward.distribution(reward)
    if not ns.Outbox.directory():get(readers[1]) then
        ns.Outbox.requestKeys()
        GBA.Print("|cffffcc00fetching " .. readers[1] .. "'s key; press Claim again in a moment|r")
        return false
    end

    -- Only the fact types the offer's ticked categories cover.
    local allowed = {}
    for name in pairs(Reward.factsFor(reward.data)) do
        local code = GBA.Schema.factType[name]
        if code then allowed[code] = true end
    end
    if next(allowed) == nil then
        return GBA.Print("|cffffcc00this offer asks only for data nothing records yet; nothing to send|r")
    end

    ns.Submit.prepare()
    local facts, sessions = ns.Submit.gather(attach == Reward.attach.session and state.sessionID or nil, allowed)
    local payload = { schemaVersion = GBA.Schema.VERSION, facts = facts, sessions = sessions }

    GBA.Print("locking your data so only " .. table.concat(readers, ", ") .. " can read it...")
    local sid, err = ns.Outbox.submit(payload, readers, function(sid)
        local letter = ns.Outbox.letters(sid)[1]
        if not letter or letter.to ~= readers[1] then
            ns.Outbox.cancel(sid)
            return GBA.Print("|cffff4040could not lock a key letter for " .. readers[1] .. "; nothing was sent|r")
        end
        if not Mailbox.isOpen() then return ns.Outbox.cancel(sid) end
        fillClaimMail(reward, items, copper, recipient, sid, letter)
    end, true)
    if not sid then GBA.Print("|cffff4040" .. tostring(err) .. "|r") end
    return sid ~= nil
end

-- The extra readers' key letters, one mail each. Resumed at every mailbox visit until each
-- has gone, because a letter never mailed is a reader who can never open the session.
function Flow.resumeLetters()
    if pending or not Mailbox.isOpen() then return end
    local list = {}
    if ns.Outbox then
        for _, l in ipairs(ns.Outbox.unsentLetters()) do
            list[#list + 1] = { kind = "key", to = l.to, sid = l.sid, body = l.body }
        end
    end
    if ns.myClaims then
        for _, due in ipairs(ns.myClaims:lettersDue()) do
            list[#list + 1] = { kind = "decider", to = due.to, entry = due.entry }
        end
    end
    if #list == 0 then letterQueue = nil; return end
    letterQueue = { list = list, i = 1 }
    Flow.nextLetter()
end

-- One letter of the queue, filled in. Each is marked sent only when THAT letter goes: a key
-- letter counted as sent that never went is a reader who can never open the session
-- (docs/fix-plan.md, NEW-1), and a decider's letter is how every decider is mailed the claim.
function Flow.nextLetter()
    local q = letterQueue
    if not q or pending then return end
    local l = q.list[q.i]
    if not l then
        letterQueue = nil
        return GBA.Print("|cff40ff40every letter has been sent|r")
    end
    local subject, body, what, onSent
    if l.kind == "key" then
        subject, body, what = letterSubject(l.sid), l.body, "key letter"
        onSent = function() ns.Outbox.markLetterSent(l.sid, l.to) end
    else
        local e = l.entry
        subject, what = claimLetterSubject(e.title), "claim letter"
        local poster = e.issuer and (e.issuer:match("^([^%-]+)") or e.issuer) or "its poster"
        body = "Claiming: " .. tostring(e.title) .. NEWLINE .. NEWLINE
            .. "You are one of this offer's deciders. What it asked for went to " .. poster .. "."
        onSent = function() ns.myClaims:letterSent(e.rewardID, e.at, l.to) end
    end
    local attached, why = ns.MailSend.prepare(l.to, subject, body, {})
    if not attached then return GBA.Print("|cffff4040" .. tostring(why) .. "|r") end
    watch:expect("letter", {
        recipient = l.to,
        subject = subject,
        onSent = function()
            onSent()
            if letterQueue == q then
                q.i = q.i + 1
                C_Timer.After(0.5, Flow.nextLetter)
            end
        end,
        onFailed = function(_, reason)
            GBA.Print("|cffff4040the " .. what .. " for " .. l.to .. " did not go:|r " .. tostring(reason or "the game refused it")
                .. ". It stays unsent; press Send again.")
        end,
    })
    GBA.Print(string.format("%s %d of %d, for %s, is ready: press |cff00d1ffSend|r", what, q.i, #q.list, l.to))
end

-- Sending for the player, when they have asked for that. Still one confirmation, because
-- items leaving a bag cannot be undone and the whole point of the manual path is that a
-- person looked at the slots first.
StaticPopupDialogs["GUILDLEDGER_CONFIRM_SEND"] = {
    text = "%s",
    button1 = "Send it",
    button2 = CANCEL or "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function() Flow.post() end,
}

StaticPopupDialogs["GUILDLEDGER_CONFIRM_CLAIM"] = {
    text = "%s",
    button1 = "Claim it",
    button2 = CANCEL or "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function() Flow.send(state.reward) end,
}

function Flow.autoSend()
    if not pending then return false end

    local names = Resolve.live(GBA.spokes)
    local lines = {
        "Send this to " .. pending.recipient .. "?",
        "",
        "Items:  " .. (Reward.describeEntries(pending.items, Resolve, names) or "none"),
        "Gold:   " .. (pending.copper > 0 and Resolve.money(pending.copper) or "none"),
        "Data:   " .. Reward.describeAttachment(pending.reward.attach),
        "",
        "Items and gold cannot be taken back.",
    }
    StaticPopup_Show("GUILDLEDGER_CONFIRM_SEND", table.concat(lines, NEWLINE))
    return true
end

-- Posts the mail the addon filled in. Only ever reached through a confirmation.
function Flow.post()
    if not pending then return end

    local body = GBA.MailBody.get()
    local ok, err = ns.MailSend.post(pending.recipient, pending.reward.title, body)
    if not ok then
        -- The mail is left filled in rather than cleared: the player can still press Send
        -- themselves, and clearing would strand the items on the frame.
        return GBA.Print("|cffff4040mail not sent:|r " .. tostring(err))
    end

    -- The mail watch does the rest, the same as for a mail sent by hand: SendMail ran, and
    -- its own success or failure completes the claim or leaves it waiting.
end

-- An offer with nothing to hand over: no mail, so the claim is the act.
function Flow.confirmBare(reward)
    local lines = {
        "Claim \"" .. reward.title .. "\"?",
        "",
        "Nothing is posted: this offer asks for no items.",
        "Data:   " .. Reward.describeAttachment(reward.attach),
    }
    StaticPopup_Show("GUILDLEDGER_CONFIRM_CLAIM", table.concat(lines, NEWLINE))
    return true
end

-- Sends the claim record itself. Called after the mail has gone, or directly for an offer
-- that had nothing to post.
function Flow.send(reward, sending, note, transferID, lettersDue)
    if not ns.sendClaim then
        return GBA.Print("|cffff4040the claim sender is not loaded|r")
    end

    local ok, err = ns.sendClaim({
        reward = reward,
        sending = sending or wantedItems(reward),
        note = note,
        sessionID = state.sessionID,
        transferID = transferID,
        lettersDue = lettersDue,
    })
    if not ok then return GBA.Print("|cffff4040" .. tostring(err) .. "|r") end

    state.sessionID = nil
    if ns.RewardsPanel and ns.RewardsPanel.built() then
        ns.RewardsPanel.showList()
    end
    return true
end

-- The mail going out is what completes a claim -----------------------------------

-- `mail` is what the game was actually handed: the claim records what went, which is not
-- always what the offer asked for (docs/fix-plan.md, D13).
function Flow.finish(claim, mail)
    local sending = {}
    for _, item in ipairs(mail.items or {}) do
        sending[#sending + 1] = { itemID = item.itemID, quantity = item.count or 1 }
    end
    -- The gold posted is part of what was sent, so it belongs on the record of it.
    if (mail.money or 0) > 0 then sending[#sending + 1] = { money = mail.money } end

    state.sessionID = claim.sessionID
    local transferID = claim.transferID
    if transferID then
        -- Send went: only now does the locked session leave this computer.
        ns.Outbox.markLetterSent(transferID, claim.recipient)
        ns.Outbox.release(transferID)
    end
    -- Every other decider is mailed the claim too (DEC-5), except one already getting a key
    -- letter for it, which says the same.
    local skip = { [claim.recipient] = true }
    if transferID then
        for _, reader in ipairs(Reward.distribution(claim.reward)) do skip[reader] = true end
    end
    local lettersDue = {}
    for _, name in ipairs(Reward.deciderList(claim.reward)) do
        if not skip[name] then lettersDue[#lettersDue + 1] = name end
    end
    if #lettersDue > 0 then
        GBA.Print(string.format("a letter to each of the offer's other deciders follows: %s", table.concat(lettersDue, ", ")))
    end
    Flow.send(claim.reward, sending, stripLetters(mail.body), transferID, lettersDue)
    if pending == claim then pending = nil end
    C_Timer.After(0.5, Flow.resumeLetters)
end

Mailbox.onOpen(function()
    C_Timer.After(1, Flow.resumeLetters)

    -- The tab strip is asked to attach here rather than waited on.
    --
    -- This handler and Core's both run on opening the mailbox, and which runs first is decided
    -- by load order, not by anything either of them should depend on. Reading `attached` was
    -- reading it before the tab had had its turn, so the window opened every time and the tab
    -- was then handed that window as its panel. attach() is idempotent, so asking is free and
    -- the answer is never early.
    local attached = GBA.MailTabs and GBA.MailTabs.attach()
    if attached then return end

    -- A client whose mail frame would not take a third tab gets the window instead.
    local held = ns.rewardCatalog and ns.rewardCatalog:count() or 0
    if held > 0 and ns.RewardsPanel then ns.RewardsPanel.openWindow() end
end)

Mailbox.onClose(function()
    -- A prepared mail that was never sent is not a claim. Dropped rather than kept, because a
    -- stale one would attach itself to whatever the player posts next. Its locked data never
    -- left, and is deleted with it. A claim mail already in flight is not prepared any more:
    -- its answer still comes, and completes it.
    watch:cancel("claim")
    watch:cancel("letter")
    if pending and watch:flying() ~= "claim" then
        if pending.transferID then ns.Outbox.cancel(pending.transferID) end
        pending = nil
    end
    letterQueue = nil
    if ns.RewardsPanel then ns.RewardsPanel.closeWindow() end
end)

-- Settings and commands -----------------------------------------------------------

