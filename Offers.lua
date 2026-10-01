-- The officer's side: write a reward, then put it on the guild's channel.
--
-- A reward is filled in rather than configured. The officer writes what they want and what
-- they will give in their own words, because a person reads the claim and judges it — the
-- addon never parses either. The single structured choice is how much telemetry comes
-- attached, because that is the only part the addon has to physically gather.
--
-- Nothing here is typed. The Offers mail tab (OfferComposer) is where an officer writes one; this file only
-- issues what it hands over and puts it on the channel.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Codec, Schema, Reward, Resolve = GBA.Codec, GBA.Schema, GBA.Reward, GBA.Resolve

local catalog = Reward.Catalog.new()
ns.offerCatalog = catalog

local function issuer()
    local name = UnitName("player")
    local realm = GetRealmName and GetRealmName() or nil
    return GBA.Provenance.observerKey({ name = name, realm = realm })
end

-- Sends the given rewards to the guild. Returns parts or nil, reason.
local function broadcast(rewards, kind, distribution, target)
    local wire = {}
    for _, reward in ipairs(rewards) do wire[#wire + 1] = reward end
    if #wire == 0 then return nil, "nothing to send" end

    local encoded = Codec.encode({
        kind = kind or Schema.messageKind.reward,
        envelope = { schemaVersion = Schema.VERSION },
        rewards = wire,
    }, Codec.MODE_CHANNEL)
    if not encoded then return nil, "could not encode" end

    return GBA.Channel.send(encoded, distribution or "GUILD", target)
end

ns.broadcastRewards = broadcast

-- Signs an offer with this officer's signature key, when there is one. Every revision is signed
-- afresh: the catalog clears the old signature when it makes a new revision.
-- Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md.
-- Signed as a job (GBA.edJob), because a signature worked out whole is enough for the game to
-- stop the addon; then(reward) runs once the signature is on. With no signature key, then runs
-- at once and the offer goes unsigned, which the unsigned rule still accepts from its issuer.
local function signOffer(reward, then_)
    local seed, public
    if ns.Vault and ns.Vault.signer then seed, public = ns.Vault.signer() end
    if not seed or not reward then return then_ and then_(reward) end
    GBA.edJob(function() return GBA.OfferSig.sign(reward, seed, public) end, function(sig)
        reward.sig = sig
        if then_ then then_(reward) end
    end)
end

-- This officer's own offers that carry no signature yet (posted before the key existed), signed
-- and sent again so any officer can pass them along. With all, every one of them is re-signed:
-- for when the key is newly stamped. done(n) once they have gone.
local function signOwn(all, done)
    local me, mine = UnitName("player"), {}
    for _, reward in ipairs(catalog:all()) do
        if Reward.issuerMatches(reward.issuer, me) and (all or not reward.sig) then mine[#mine + 1] = reward end
    end
    if #mine == 0 then return done and done(0) end
    local left, sent = #mine, {}
    for _, reward in ipairs(mine) do
        signOffer(reward, function(signed)
            if signed.sig then sent[#sent + 1] = signed end
            left = left - 1
            if left == 0 then
                if #sent > 0 then (ns.tellOffers or broadcast)(sent) end
                if done then done(#sent) end
            end
        end)
    end
end

local stampedWith = nil
GBA.onRoleList(function()
    local mine = ns.Vault and ns.Vault.signPublic and ns.Vault.signPublic()
    if not mine or GBA.roles:keyOf(UnitName("player")) ~= mine or stampedWith == mine then return end
    stampedWith = mine
    signOwn(true, function(n)
        if n > 0 then GBA.Print("your signature key is stamped; signed and re-sent " .. n .. " of your offer(s)") end
    end)
end)

-- What this officer can hand on: its own offers, removed ones included (a player who missed a
-- removal learns it this way), then every signed offer from other officers this client has
-- verified, so a member can get any officer's offer from whichever officer is online.
function ns.relayable()
    local list = catalog:all()
    local own = {}
    for _, reward in ipairs(list) do own[reward.id] = true end
    if ns.rewardCatalog and ns.offerVerified then
        for _, reward in ipairs(ns.rewardCatalog:all()) do
            if not own[reward.id] and reward.sig and ns.offerVerified(reward) then list[#list + 1] = reward end
        end
    end
    return list
end

-- The offer handshake --------------------------------------------------------------------------
--
-- Spec: docs/superpowers/specs/2026-09-24-guild-propagation-and-soak-design.md, part 1.
-- Whoever meets an officer sends a summary: per poster, how many offers and a digest. The officer
-- answers with the full list only for posters whose digests differ, and always with its own
-- summary (so the asker knows it was heard, and another officer can send its lists back). The
-- asker then asks for exactly the offers it lacks. Where everything matches, the whole exchange is
-- one small message each way.
local Summary = GBA.Summary

local function sendTo(who, payload, distribution)
    payload.envelope = { schemaVersion = Schema.VERSION }
    local encoded = Codec.encode(payload, Codec.MODE_CHANNEL)
    if encoded then return GBA.Channel.send(encoded, distribution or "WHISPER", who) end
end

-- News of this officer's own offers, when one is posted, edited, removed or signed. By default
-- the offers themselves go to the guild, once. With config.offerNews = "list" only the list of
-- this officer's offers goes (ids and revisions, no content), and whoever is behind asks for what
-- it lacks: nothing is sent that was not asked for. Which is quieter is for the soak to measure.
function ns.tellOffers(rewards)
    if ns.config and ns.config.offerNews == "list" then
        local lists = Summary.lists(catalog:all())
        local me = issuer()
        if lists[me] then
            return sendTo(nil, { kind = Schema.messageKind.offerList, author = me, entries = lists[me] }, "GUILD")
        end
        return nil, "nothing to tell"
    end
    return broadcast(rewards)
end

GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end
    local kind = payload.kind
    if kind ~= Schema.messageKind.offerSummary and kind ~= Schema.messageKind.offerWant then return end
    if not payload.envelope or payload.envelope.schemaVersion ~= Schema.VERSION then return end
    if not (GBA.mayAct("officer") or GBA.mayAct("offer")) then return end

    if kind == Schema.messageKind.offerWant then
        local want = {}
        for _, id in ipairs(type(payload.ids) == "table" and payload.ids or {}) do want[id] = true end
        local out = {}
        for _, reward in ipairs(ns.relayable()) do
            if want[reward.id] then out[#out + 1] = reward end
        end
        if #out > 0 then broadcast(out, Schema.messageKind.rewardCatalog, "WHISPER", sender) end
        return
    end

    if type(payload.summary) ~= "table" then return end
    local held = ns.relayable()
    local mine, lists = Summary.of(held), Summary.lists(held)
    for _, author in ipairs(Summary.differs(mine, payload.summary)) do
        if lists[author] then
            sendTo(sender, { kind = Schema.messageKind.offerList, author = author, entries = lists[author] })
        end
    end
    -- "I'm checking too": always answered with this officer's own summary, which is also how the
    -- asker knows it was heard. A reply is never answered, so each pair exchanges one summary
    -- each way and stops.
    if not payload.reply then
        sendTo(sender, { kind = Schema.messageKind.offerSummary, summary = mine, reply = true })
        -- And any decision owed to them goes too: they asked (a zone change, the mailbox), so
        -- nothing waits for a clock (the user's rule: if somebody checks with you, you check too).
        if ns.tellClaimant then ns.tellClaimant(GBA.Net.short(sender), nil, true) end
    end
end)

-- A player who was offline when a reward went out never heard it, because the channel
-- queues nothing. Answering their query is the only way they ever catch up, so this is not
-- a convenience - it is the other half of delivery.
GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end
    if payload.kind ~= Schema.messageKind.catalogQuery then return end
    -- Said, not silent: a request dropped quietly looks the same as one never sent, and a
    -- version mismatch between two clients is the usual reason for one.
    local asked = payload.envelope and payload.envelope.schemaVersion
    if asked ~= Schema.VERSION then
        return GBA.Print(string.format("|cffffcc00ignored a request for rewards from %s: schema v%s, this client reads v%d. One of you needs to update and /reload.|r",
            tostring(sender), tostring(asked), Schema.VERSION))
    end

    local list = ns.relayable()

    -- Whispered back to whoever asked rather than broadcast again, so one player catching
    -- up does not re-send the catalog to everybody online. Answered even when empty, so the
    -- player can tell "nothing on offer" from "no answer".
    if #list == 0 then
        local encoded = Codec.encode({ kind = Schema.messageKind.rewardCatalog,
            envelope = { schemaVersion = Schema.VERSION }, rewards = {} }, Codec.MODE_CHANNEL)
        if encoded then GBA.Channel.send(encoded, "WHISPER", sender) end
        return GBA.Print(string.format("%s asked for rewards; you have none on offer", tostring(sender)))
    end
    local parts = broadcast(list, Schema.messageKind.rewardCatalog, "WHISPER", sender)
    if parts then
        GBA.Print(string.format("sent %d reward(s) to %s on request", #list, tostring(sender)))
    end
end)

-- What the builder calls when Publish is pressed. The UI holds no logic of its own; it
-- fills these fields in and hands them here, which is also why the same call will serve a
-- second way of building a reward if one ever exists.
function ns.publishReward(fields)
    local who = issuer()
    if not who then return nil, "cannot tell who you are; try /reload" end

    local now = GBA.now()
    local reward, err = catalog:issue({
        issuer = who,
        title = fields.title,
        -- How it reads in the player's list, and who it is for. Optional, and revalidated
        -- on the other side like everything else that crosses the wire.
        flavor = fields.flavor,
        body = fields.body,
        icon = fields.icon,
        quality = fields.quality,
        requires = fields.requires,
        wants = fields.wants,
        gives = fields.gives,
        attach = fields.attach,
        -- What the offer asks the player to share. Missing from this list until the
        -- composer started setting it, which is the same way the icon and the body went.
        data = fields.data,
        -- Who besides the issuer gets a key letter for what a claim carries.
        readers = fields.readers,
        -- Who besides the issuer may decide its claims (DEC-4).
        deciders = fields.deciders,
        -- Who the offer is for (the composer's To list); nil is everyone.
        audience = fields.audience,
        -- The hard-list quest this offer switches on (HardSwitches.lua); nil for an officer's own.
        hardID = fields.hardID,
        issuedAt = now,
        -- Revoking over a channel that queues nothing is unreliable: anyone offline when
        -- the retraction goes out keeps the stale offer. An expiry retracts without
        -- needing the other client present.
        expiresAt = now + Reward.DEFAULT_DAYS * 86400,
    })
    if not reward then return nil, err end
    -- Sent once it is signed, a moment later.
    signOffer(reward, function()
        local parts, reason = ns.tellOffers({ reward })
        if not parts then
            GBA.Print("|cffffcc00published locally but not sent:|r " .. tostring(reason))
        else
            GBA.Print(string.format("|cff40ff40offered \"%s\"|r to the guild in %d message(s)",
                reward.title, parts))
            GBA.Print("  only players online right now received it; the rest get it when they ask")
        end
    end)
    return reward
end

-- Only the character that issued an offer can change it: every client checks that an offer
-- comes from its issuer, so an edit sent by anyone else would be refused on arrival anyway.
local function mine(id)
    local held = catalog:live(id)
    if not held then return nil, "that offer is not on offer" end
    if not GBA.mayAct("offer") then return nil, "you may not publish offers" end
    if not Reward.issuerMatches(held.issuer, UnitName("player")) then
        return nil, "only " .. tostring(held.issuer) .. ", who posted it, can change it"
    end
    return held
end

local function announce(reward, doing)
    local parts, reason = ns.tellOffers({ reward })
    if not parts then
        GBA.Print("|cffffcc00" .. doing .. " here but not sent:|r " .. tostring(reason))
    else
        GBA.Print(string.format("|cff40ff40%s \"%s\"|r for the guild", doing, reward.title))
    end
    if ns.offersTab then ns.offersTab.setCount(catalog:count()) end
end

-- The composer's Post, when it is editing an offer rather than writing a new one. Takes the
-- same fields as publishReward; the id, issuer and first-issued time stay the offer's own.
function ns.reviseReward(id, fields)
    local held, why = mine(id)
    if not held then return nil, why end
    local reward, err = catalog:revise(id, fields, GBA.now())
    if not reward then return nil, err end
    signOffer(reward, function() announce(reward, "changed") end)
    return reward
end

-- The edit screen's Remove.
function ns.retractReward(id)
    local held, why = mine(id)
    if not held then return nil, why end
    local reward, err = catalog:retract(id)
    if not reward then return nil, err end
    signOffer(reward, function() announce(reward, "removed") end)
    return reward
end

-- Claims arriving from players.
--
-- Held rather than folded. The gate belongs in front of ingest, not in front of the view:
-- a client that folds a claim it has not accepted has already absorbed what the officer
-- was meant to decide on, and the fold is one-way.
-- What arrived, what was decided, who has been awarded each offer, and which decisions the
-- player has not heard yet. Saved by Guild.lua; see OfficerClaims.
local officerClaims = GBA.OfficerClaims.new()
ns.officerClaims = officerClaims

-- The live offer whose claims this officer may decide, or nil: its own, or another poster's that
-- names this officer as a decider (docs/fix-plan.md, DEC-4). Deciding is a publisher's job.
function ns.decidable(rewardID)
    if not GBA.mayAct("offer") then return nil end
    local own = catalog:live(rewardID)
    if own then return own end
    local theirs = ns.rewardCatalog and ns.rewardCatalog:live(rewardID)
    if theirs and Reward.isDecider(theirs, UnitName("player")) then return theirs end
    return nil
end

-- Tells a player this officer has their claim, so their client stops the quick retries; with
-- saved, that it is on this officer's disk, so their client stops offering it at check-ins too
-- (docs/fix-plan.md, DEC-6).
local function ackClaim(to, claim, saved)
    local encoded = Codec.encode({ kind = Schema.messageKind.claimAck,
        envelope = { schemaVersion = Schema.VERSION }, rewardID = claim.rewardID, at = claim.at,
        saved = saved or nil },
        Codec.MODE_CHANNEL)
    if encoded then GBA.Channel.send(encoded, "WHISPER", to) end
end

-- Tells a player this officer could not take their claim, and why, rather than saying nothing
-- while their client sends it again and again (docs/fix-plan.md, E4). The player keeps offering
-- it at check-ins: another officer may be able to take it. Never sent to someone outside the
-- guild, and the envelope is not checked on arrival, so a version mismatch can be told.
local function refuseClaim(to, claim, reason)
    if type(claim) ~= "table" or claim.rewardID == nil then return end
    local encoded = Codec.encode({ kind = Schema.messageKind.claimRefused,
        envelope = { schemaVersion = Schema.VERSION }, rewardID = claim.rewardID, at = claim.at,
        reason = reason }, Codec.MODE_CHANNEL)
    if encoded then GBA.Channel.send(encoded, "WHISPER", to) end
end

-- What an officer should check before deciding a claim just held here.
-- A guild quest's evidence, recounted here with the same counting the player's addon used
-- (hard-quest spec, Part 3). Sets record.verified = { have, need, done } and returns it, or nil
-- for an offer that is not a guild quest. A mail step counts what the claim mail carried.
function ns.verifyEvidence(record, reward)
    local hardID = type(reward) == "table" and reward.hardID
    if not hardID then return nil end
    local entry
    for _, e in ipairs(GBA.HardList or {}) do if e.id == hardID then entry = e break end end
    if not entry then return nil end
    local ev = record.evidence
    if type(ev) ~= "table" then
        record.verified = { none = true }
        return record.verified
    end
    local facts = {}
    for code, rows in pairs(ev.facts or {}) do
        for _, row in ipairs(rows) do
            local values, chain = Schema.fromWire(code, row)
            if values then
                chain = chain or {}
                facts[#facts + 1] = { code = code, v = values,
                    time = (chain.sessionID or 0) + (chain.t or 0), seq = chain.seq or 0 }
            end
        end
    end
    table.sort(facts, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.seq < b.seq
    end)
    local held = {}
    for _, item in ipairs(record.sending or {}) do
        if item.itemID then held[item.itemID] = (held[item.itemID] or 0) + (item.quantity or 1) end
    end
    local ok, p = pcall(GBA.HardQuest.progress, entry, facts,
        { since = ev.acceptedAt, held = held, zoneOf = ns.zoneOf })
    if not ok or type(p) ~= "table" then return nil end
    local have, need = 0, 0
    for _, step in ipairs(p.steps) do have, need = have + step.have, need + step.need end
    record.verified = { have = have, need = need, done = p.done == true }
    return record.verified
end

-- The verification in words, for chat and the Claims drawer.
function ns.verifiedText(v)
    if not v then return nil end
    if v.none then return "|cffffcc00no evidence came with it (an older addon?)|r" end
    if v.done then return string.format("|cff40ff40verified %d / %d|r", v.have, v.need) end
    return string.format("|cffff4040not verified: %d / %d|r", v.have, v.need)
end

local function claimWarnings(record, reward)
    local verified = ns.verifiedText(ns.verifyEvidence(record, reward))
    if verified then GBA.Print("  " .. verified) end
    if record.repeated then
        GBA.Print("|cffffcc00  already awarded this offer, and not requeued: check before awarding again|r")
    end
    -- The offer was edited after the player claimed it: judge the claim against what they saw
    -- (docs/fix-plan.md, D9, E6).
    if record.revision and reward and reward.revision and record.revision ~= reward.revision then
        GBA.Print(string.format("|cffffcc00  claimed against revision %d; the offer has been edited since (now %d)|r",
            record.revision, reward.revision))
    end
end

-- A claim just received goes straight on to every other officer online, so it sits on more than
-- one computer before anyone has saved it; whichever of them next reloads or logs out saves it for
-- the guild (DEC-6). Once per claim per session, and never passed on again by those who get it.
-- Alone, nobody else can hold it: this officer is told a reload is what keeps it.
local spreadDone = {}
local function spreadClaim(id, claim, from, issuerName, saved)
    if spreadDone[id] then return end
    spreadDone[id] = true
    local copies = 0
    for _, officer in ipairs(GBA.onlineOfficers()) do
        if GBA.Net.short(officer) ~= GBA.Net.short(from) then
            sendTo(officer, { kind = Schema.messageKind.claimCopy, id = id, from = from,
                issuer = issuerName, claim = claim, saved = saved or nil })
            copies = copies + 1
        end
    end
    if copies == 0 and not saved then
        GBA.Print("|cffffcc00data incoming:|r you are the only officer online, so this claim is only in"
            .. " memory until you reload or log out. |cff806030/reload|r saves it.")
    end
end

-- Claims turned away, by reason. Shown by /gba inbox so a refusal is never invisible.
local refused = { notAllowed = 0, notMine = 0, notInGuild = 0 }
ns.claimRefusals = refused

-- Three checks before a claim is held, because a claim can carry a player's telemetry and
-- holding it is already reading it:
--
--   1. this client may receive claims at all. Installing the Guild addon is not a
--      permission; before this, any member who installed it held every claim broadcast.
--   2. the claim is for a reward THIS client issued. Claims are whispered to the issuer,
--      so anything else arriving here was not meant for us - an older client still
--      broadcasting, or somebody fishing. Quietly counted, since the first case is
--      expected while the guild updates.
--   3. the sender is in the guild, as the roster reports it. The sender is the
--      server-attested one; claim.from is written by the claimant and not trusted here.
--
-- Every check leans toward holding less. An unknown rank, an unknown reward and an
-- unknown sender are all refusals.
GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end
    if payload.kind ~= Schema.messageKind.rewardClaim then return end

    -- A publisher takes claims on their own offers; any officer holds claims for a publisher
    -- who is offline.
    if not GBA.mayAct("offer") and not GBA.mayAct("officer") then
        refused.notAllowed = refused.notAllowed + 1
        return
    end

    local sent = payload.envelope and payload.envelope.schemaVersion
    if sent ~= Schema.VERSION then
        if GBA.rosterRankOf(sender) ~= nil then
            refuseClaim(sender, payload.claim, string.format(
                "%s's addon reads version %d and yours sent %s: one of you needs to update",
                GBA.Net.short(sender), Schema.VERSION, tostring(sent)))
        end
        return GBA.Print(string.format(
            "|cffffcc00ignored a claim from %s: schema v%s, this client reads v%d|r",
            tostring(sender), tostring(sent), Schema.VERSION))
    end

    local claim = Reward.claim(payload.claim or {})
    if not claim then
        return GBA.Print("|cffffcc00a claim from " .. tostring(sender) .. " was malformed|r")
    end

    if GBA.rosterRankOf(sender) == nil then
        refused.notInGuild = refused.notInGuild + 1
        return GBA.Print(string.format(
            "|cffff4040refused a claim from %s|r: not in the guild roster", tostring(sender)))
    end

    -- A player offers an unsaved claim again at every check-in (DEC-6). One already held here is
    -- answered, and not announced a second time.
    local known = officerClaims:find(GBA.OfficerClaims.idOf(sender, claim.at))

    -- A removed offer cannot be claimed; one claimed just before it went is refused too.
    local reward = ns.decidable(claim.rewardID)
    if not reward then
        -- Another officer's live offer, and they are offline: held for them, and passed on when
        -- they log in. The player is told it is held, so their client stops sending it.
        local theirs = ns.rewardCatalog and ns.rewardCatalog:live(claim.rewardID)
        if theirs and GBA.mayAct("officer") and not Reward.issuerMatches(theirs.issuer, UnitName("player")) then
            local held = officerClaims:holdFor(claim, sender, theirs.issuer, GBA.now())
            if held then
                ackClaim(sender, claim, held.saved)
                spreadClaim(held.id, claim, held.from, held.issuer, held.saved)
                if known then return end
                GBA.Print(string.format("holding %s's claim for \"%s\" until %s is online",
                    GBA.Net.short(sender), tostring(theirs.title), held.issuer))
                if ns.passOnHeld then ns.passOnHeld(held.issuer) end
            end
            return
        end
        refused.notMine = refused.notMine + 1
        local known = ns.rewardCatalog and ns.rewardCatalog:get(claim.rewardID)
        refuseClaim(sender, claim, known and known.retracted
            and "the offer was removed; what happens now is up to the officer who posted it"
            or (GBA.Net.short(UnitName("player")) .. " cannot take claims on that offer"))
        return
    end

    local record = officerClaims:receive(claim, reward, sender, GBA.now())
    if not record then return end
    ackClaim(sender, claim, record.saved)
    spreadClaim(record.id, claim, record.from, UnitName("player"), record.saved)
    if known then return end
    -- Outside the offer's audience: declined at once, so the player hears why rather than
    -- waiting. Only a client that ignored the audience can send one.
    if record.state == Reward.state.submitted and not Reward.inAudience(reward, GBA.rosterMember(sender)) then
        ns.declineClaim(record.id)
        return GBA.Print(string.format("|cffffcc00declined %s's claim for \"%s\"|r: not in the offer's audience",
            record.from, reward.title))
    end

    local names = Resolve.live(GBA.spokes)
    GBA.Print(string.format("|cff40ff40%s claimed \"%s\"|r",
        tostring(sender), reward and reward.title or tostring(claim.rewardID)))
    claimWarnings(record, reward)
    -- They are online now: anything they have not heard yet goes with this.
    if ns.tellClaimant then ns.tellClaimant(record.from) end

    local sending = Reward.describeEntries(claim.sending, Resolve, names)
    if sending then GBA.Print("  sending: " .. sending) end
    if claim.note then GBA.Print("  note: " .. claim.note) end

    GBA.Print("  attached: " .. Reward.describeAttachment(claim.attach))
    if claim.transferID then
        GBA.Print("  data: session " .. claim.transferID .. " (" .. (ns.Vault and ns.Vault.status(claim.transferID) or "?") .. ")")
    end
    GBA.Print("  review it at a mailbox")
end)

-- Telling the player -----------------------------------------------------------------------
--
-- A decision reaches the player as a whisper, and is sent again until they acknowledge it:
-- whenever they claim, whenever this officer logs in, and once a minute while they are
-- online. So an award made while the player was offline still lands.
--
-- Decisions are signed by the officer who made them and shared with every online officer, who
-- check the signature, log it, and deliver it too: the decider and the player may never be
-- online together (Holdy and Nuurseted share an account). The first acknowledgement ends it
-- for everyone. Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md, part B.

local function sendTo(name, payload)
    payload.envelope = { schemaVersion = Schema.VERSION }
    local encoded = Codec.encode(payload, Codec.MODE_CHANNEL)
    if encoded then return GBA.Channel.send(encoded, "WHISPER", name) end
end

-- A notice as it travels: what was decided, for whom, and when signed, by whom with the proof.
local function wire(n)
    return { key = n.key, kind = n.kind, to = n.to, rewardID = n.rewardID, at = n.at, state = n.state,
        by = n.by, signedAt = n.signedAt, sig = n.sig }
end

-- Who delivers a decision, when several officers carry it: the officer who made it if online,
-- otherwise the online officer whose name sorts first. Every officer works it out the same way,
-- so one sends and the others stay quiet (propagation spec, part 4: shared jobs use a fixed rule).
local function deliverer(n)
    local online, first = {}, nil
    -- GBA.onlineOfficers() leaves this character out; it counts here, or two officers would each
    -- pick the other and neither deliver.
    local everyone = GBA.onlineOfficers()
    if GBA.mayAct("officer") then everyone[#everyone + 1] = UnitName("player") end
    for _, officer in ipairs(everyone) do
        officer = GBA.Net.short(officer)
        online[officer] = true
        if not first or officer < first then first = officer end
    end
    local by = n.by and GBA.Net.short(n.by)
    if by and online[by] then return by end
    return first or UnitName("player")
end

-- Retrying one delivery: 30, 60, then 120 seconds later, only while the player has not
-- acknowledged it and is still online; it stops as soon as they do.
local TELL_AGAIN = { 30, 60, 120 }
local telling = {}         -- player -> the retry under way

-- Sends a player what they have not acknowledged, if they are online and this officer is the one
-- to deliver it: its own decisions, and the signed ones it carries for other officers. With
-- asked (the player just checked in with this officer), whatever it holds for them, whoever the
-- fixed rule would pick: asked is answered.
function ns.tellClaimant(name, try, asked)
    local me = UnitName("player")
    local notices = {}
    for _, n in ipairs(officerClaims:toDeliver(name)) do
        if asked or deliverer(n) == me then notices[#notices + 1] = n end
    end
    if #notices == 0 then telling[name] = nil; return 0 end
    local _, online = GBA.rosterEntry(name)
    if online == false then telling[name] = nil; return 0 end
    for _, n in ipairs(notices) do
        sendTo(name, { kind = Schema.messageKind.claimNotice, notice = wire(n) })
    end
    try = try or 1
    if TELL_AGAIN[try] and telling[name] ~= try then
        telling[name] = try
        C_Timer.After(TELL_AGAIN[try], function()
            if telling[name] == try then ns.tellClaimant(name, try + 1) end
        end)
    end
    return #notices
end

local function tellEveryone()
    local seen = {}
    for _, n in ipairs(officerClaims:toDeliver()) do
        if not seen[n.to] then seen[n.to] = true; ns.tellClaimant(n.to) end
    end
end

-- Sharing with the other officers. Each signed decision goes once per officer per session, and
-- each officer is told once per session which decisions were already delivered.
local sharedWith, deliveredTold = {}, {}

local function shareDecision(n)
    if not n.sig then return end
    sharedWith[n.key] = sharedWith[n.key] or {}
    for _, officer in ipairs(GBA.onlineOfficers()) do
        if not sharedWith[n.key][officer] then
            sharedWith[n.key][officer] = true
            sendTo(officer, { kind = Schema.messageKind.claimDecision, notice = wire(n) })
        end
    end
end

local function tellDelivered(keys, officers)
    if #keys == 0 then return end
    for _, officer in ipairs(officers or GBA.onlineOfficers()) do
        sendTo(officer, { kind = Schema.messageKind.claimNoticeDone, keys = keys })
    end
end

local function shareAll()
    -- An officer who logged off is told again when they are back: what they missed meanwhile
    -- is exactly what they need.
    local online = {}
    for _, officer in ipairs(GBA.onlineOfficers()) do online[officer] = true end
    for officer in pairs(deliveredTold) do
        if not online[officer] then deliveredTold[officer] = nil end
    end
    for _, sent in pairs(sharedWith) do
        for officer in pairs(sent) do
            if not online[officer] then sent[officer] = nil end
        end
    end

    for _, n in ipairs(officerClaims:untold()) do shareDecision(n) end
    -- And the decisions carried for others: one of them may be the officer who made it, back
    -- after losing it (P3). An officer who still has it ignores the copy.
    for _, n in pairs(officerClaims.carried) do shareDecision(n) end
    local recent = officerClaims:deliveredSince(GBA.now() - 7 * 86400)
    while #recent > 50 do table.remove(recent, 1) end
    for _, officer in ipairs(GBA.onlineOfficers()) do
        if not deliveredTold[officer] then
            deliveredTold[officer] = true
            tellDelivered(recent, { officer })
        end
    end
end

-- This officer's own new notice: signed as a job (GBA.edJob), logged, shared and delivered.
-- Without a signature key it is delivered unsigned, straight from here, as before part B.
local function signAndSpread(notice)
    local seed, public
    if ns.Vault and ns.Vault.signer then seed, public = ns.Vault.signer() end
    if not seed then return ns.tellClaimant(notice.to) end
    notice.by, notice.signedAt = UnitName("player"), GBA.now()
    GBA.edJob(function() return GBA.OfferSig.signNotice(notice, seed, public) end, function(sig)
        notice.sig = sig
        officerClaims:signed(notice)
        shareDecision(notice)
        ns.tellClaimant(notice.to)
    end)
end

GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end
    local kind = payload.kind
    if kind ~= Schema.messageKind.claimNoticeAck and kind ~= Schema.messageKind.claimDecision
        and kind ~= Schema.messageKind.claimNoticeDone then return end
    if not payload.envelope or payload.envelope.schemaVersion ~= Schema.VERSION then return end
    local who = GBA.Net.short(sender)

    if kind == Schema.messageKind.claimNoticeAck then
        -- Only the player a notice was for can clear it; the other officers hear it was delivered.
        for _, n in ipairs(officerClaims:toDeliver(who)) do
            if n.key == payload.key then
                officerClaims:delivered(n.key, GBA.now())
                tellDelivered({ n.key })
            end
        end
        return
    end

    -- The rest comes only from officers.
    if not GBA.Authority.may("officer", { name = who, rankIndex = GBA.rosterRankOf(sender) }) then return end

    if kind == Schema.messageKind.claimNoticeDone then
        for _, key in ipairs(type(payload.keys) == "table" and payload.keys or {}) do
            if type(key) == "string" then officerClaims:delivered(key, GBA.now()) end
        end
        return
    end

    -- A decision another officer signed: checked against the key the guild master stamped for
    -- them, then carried and logged. Only a publisher decides claims.
    local n = payload.notice
    if type(n) ~= "table" or type(n.by) ~= "string" or not n.sig then return end
    if not GBA.Authority.may("offer", { name = n.by, rankIndex = GBA.rosterRankOf(n.by) }) then return end
    -- Only the offer's deciders decide its claims: its poster and whoever the poster named
    -- (DEC-4). A genuine signature from any other publisher is still refused. With the offer held
    -- here its signed list of deciders decides; without it, only the poster, whom the id names.
    local author = Reward.authorOf(n.rewardID)
    local held = catalog:get(n.rewardID) or (ns.rewardCatalog and ns.rewardCatalog:get(n.rewardID))
    local allowed
    if held then allowed = Reward.isDecider(held, n.by)
    else allowed = author ~= nil and Reward.issuerMatches(author, n.by) end
    if not allowed then
        return GBA.Print(string.format("|cffff4040refused a claim decision on \"%s\"|r: %s signed it, but is not one of its deciders",
            held and held.title or tostring(n.rewardID), n.by))
    end
    local key = GBA.roles:keyOf(n.by)
    if not key then return end
    GBA.edJob(function() return GBA.OfferSig.verifyNotice(n, key) end, function(ok)
        if not ok then
            return GBA.Print(string.format("|cffff4040refused a claim decision said to be %s's|r: its signature does not match", n.by))
        end
        -- This officer's own decision coming back: the one it lost if its game went down before
        -- saving. Restored, so the claim cannot read as undecided and be paid twice (P3).
        if Reward.issuerMatches(n.by, UnitName("player")) then
            local restored = officerClaims:restore(n)
            if restored then
                GBA.Print(string.format("restored your decision on %s's claim from %s's copy", n.to, who))
                ns.tellClaimant(n.to)
                if n.state == Reward.state.settled and ns.Vault and ns.Vault.openAccepted then pcall(ns.Vault.openAccepted) end
            end
            return
        end
        -- Another decider decided a claim this officer also holds: it is decided here too, so it
        -- is not awarded a second time from this side (DEC-4).
        local adopted = officerClaims:adopt(n)
        if adopted then
            GBA.Print(string.format("%s decided %s's claim on \"%s\"", n.by, n.to, tostring(adopted.title or n.rewardID)))
        end
        if officerClaims:carry(n) then ns.tellClaimant(n.to) end
        -- An award heard of here may open a session held here waiting for it (Vault, N2).
        if n.state == Reward.state.settled and ns.Vault and ns.Vault.openAccepted then pcall(ns.Vault.openAccepted) end
    end)
end)

-- Claims held for another officer -----------------------------------------------------------
--
-- Passed to the poster whenever they are online (on holding, and on the minute tick), until the
-- poster confirms. The poster takes a passed-on claim only from an officer, and treats it as if
-- the player had sent it: the same checks, the same record, the same decisions back to the player.

local PASS_AGAIN = { 30, 60, 120 }
local passing = {}         -- poster -> the retry under way
local posterHas = {}       -- claim id -> true once its poster said "in memory", this session

-- Claims held for this poster that still need pushing to them this session.
local function toPass(issuer)
    local out = {}
    for _, held in ipairs(officerClaims:heldFor(issuer)) do
        if not posterHas[held.id] then out[#out + 1] = held end
    end
    return out
end

-- A held claim is let go only once its poster has it on disk (DEC-6). One the poster already has
-- in memory is not pushed again this session: it stays held here, and the poster's "saved" after
-- their next reload or login settles it.
function ns.passOnHeld(issuer, try)
    local sentAny, to = 0, {}
    for _, held in ipairs(toPass(issuer)) do
        local _, online = GBA.rosterEntry(held.issuer)
        if online then
            sendTo(held.issuer, { kind = Schema.messageKind.claimRelay,
                id = held.id, from = held.from, claim = held.claim })
            sentAny = sentAny + 1
            to[held.issuer] = true
        end
    end
    -- Until the poster answers (claimRelayAck): 30, 60, 120 seconds.
    try = try or 1
    for poster in pairs(to) do
        if PASS_AGAIN[try] and passing[poster] ~= try then
            passing[poster] = try
            C_Timer.After(PASS_AGAIN[try], function()
                if passing[poster] == try then
                    if #toPass(poster) == 0 then passing[poster] = nil
                    else ns.passOnHeld(poster, try + 1) end
                end
            end)
        end
    end
    return sentAny
end

-- The poster hears a held claim is theirs again: kept after a login, too.
function ns.forgetPosterHas(poster)
    for _, held in ipairs(officerClaims:heldFor(poster)) do posterHas[held.id] = nil end
end

GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end
    if not payload.envelope or payload.envelope.schemaVersion ~= Schema.VERSION then return end
    local who = GBA.Net.short(sender)

    if payload.kind == Schema.messageKind.claimRelayAck then
        -- Only the officer it was held for can say they have it. In their memory is not enough to
        -- let it go: that waits until it is on their disk.
        for _, held in ipairs(officerClaims:heldFor(who)) do
            if held.id == payload.id then
                if payload.saved then officerClaims:passedOn(held.id) else posterHas[held.id] = true end
            end
        end
        return
    end
    if payload.kind ~= Schema.messageKind.claimRelay then return end

    -- From an officer, to the publisher it was held for.
    if not GBA.mayAct("offer") then return end
    if not GBA.Authority.may("officer", { name = who, rankIndex = GBA.rosterRankOf(sender) }) then return end

    local claim = Reward.claim(payload.claim or {})
    local from = type(payload.from) == "string" and payload.from or nil
    if not claim or not from then return end
    -- Answered only once the claim is kept here, and as saved only once it is on this disk. It
    -- used to be answered before anything was checked, and a claim for a removed offer was then
    -- dropped here after its holder had already let it go (docs/fix-plan.md, NEW-2).
    local function answer(saved)
        sendTo(sender, { kind = Schema.messageKind.claimRelayAck, id = payload.id, saved = saved or nil })
    end
    local reward = ns.decidable(claim.rewardID)
    if not reward then
        refused.notMine = refused.notMine + 1
        -- Removing an offer ends the addon's part in its claims (DEC-3): there is nothing to keep,
        -- so the holder may let it go.
        answer(true)
        return GBA.Print(string.format("|cffffcc00%s passed on a claim for an offer you no longer have|r", who))
    end
    if GBA.rosterRankOf(from) == nil then
        refused.notInGuild = refused.notInGuild + 1
        answer(true)
        return GBA.Print(string.format("|cffff4040refused a claim from %s|r: not in the guild roster", from))
    end
    local known = officerClaims:find(GBA.OfficerClaims.idOf(from, claim.at))
    local record = officerClaims:receive(claim, reward, from, GBA.now())
    if not record then return end
    answer(record.saved)
    if known then return end
    if record.state == Reward.state.submitted and not Reward.inAudience(reward, GBA.rosterMember(from)) then
        ns.declineClaim(record.id)
        return GBA.Print(string.format("|cffffcc00declined %s's claim for \"%s\"|r: not in the offer's audience",
            record.from, reward.title))
    end
    GBA.Print(string.format("|cff40ff40%s claimed \"%s\"|r (held for you by %s)", from, reward.title, who))
    claimWarnings(record, reward)
    ns.tellClaimant(record.from)
end)

-- Copies of claims, and which are saved (DEC-6) -----------------------------------------------
--
-- A copy is kept the way the officer who received it kept it: as a claim on this officer's own
-- offer, or held for the offer's poster. It is never passed on again and never answered; the
-- officer who received it answers the player. "Saved" news marks copies as on some officer's disk,
-- and when it comes from the poster a claim was held for, the hold is let go.
GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end
    local kind = payload.kind
    if kind ~= Schema.messageKind.claimCopy and kind ~= Schema.messageKind.claimSaved then return end
    if not payload.envelope or payload.envelope.schemaVersion ~= Schema.VERSION then return end
    if not (GBA.mayAct("officer") or GBA.mayAct("offer")) then return end
    local who = GBA.Net.short(sender)
    if not GBA.Authority.may("officer", { name = who, rankIndex = GBA.rosterRankOf(sender) }) then return end

    if kind == Schema.messageKind.claimSaved then
        for _, id in ipairs(type(payload.ids) == "table" and payload.ids or {}) do
            if type(id) == "string" then
                local held = officerClaims.relays[id]
                if held and held.issuer == who then officerClaims:passedOn(id) else officerClaims:markSaved(id) end
            end
        end
        return
    end

    local claim = Reward.claim(payload.claim or {})
    local from = type(payload.from) == "string" and payload.from or nil
    if not claim or not from or GBA.rosterRankOf(from) == nil then return end
    local kept
    local own = ns.decidable(claim.rewardID)
    if own then
        local known = officerClaims:find(GBA.OfficerClaims.idOf(from, claim.at))
        kept = officerClaims:receive(claim, own, from, GBA.now())
        if kept and not known then
            if kept.state == Reward.state.submitted and not Reward.inAudience(own, GBA.rosterMember(from)) then
                ns.declineClaim(kept.id)
                GBA.Print(string.format("|cffffcc00declined %s's claim for \"%s\"|r: not in the offer's audience",
                    kept.from, own.title))
            else
                GBA.Print(string.format("|cff40ff40%s claimed \"%s\"|r (received by %s)", kept.from, own.title, who))
                claimWarnings(kept, own)
            end
        end
    else
        local theirs = ns.rewardCatalog and ns.rewardCatalog:live(claim.rewardID)
        if not theirs or not GBA.mayAct("officer") or Reward.issuerMatches(theirs.issuer, UnitName("player")) then return end
        kept = officerClaims:holdFor(claim, from, theirs.issuer, GBA.now())
    end
    if kept and payload.saved then officerClaims:markSaved(kept.id) end
end)

-- What this officer has on disk: told once per session to each officer online, so their copies are
-- known to be safe, and to each claimant online, so their client stops offering the claim.
local savedTold, savedAcked = {}, {}

local function tellSaved(officers)
    local ids = {}
    for _, c in ipairs(officerClaims:openSaved()) do ids[#ids + 1] = c.id end
    if #ids == 0 then return end
    while #ids > 100 do table.remove(ids, 1) end
    for _, officer in ipairs(officers or GBA.onlineOfficers()) do
        if not savedTold[officer] then
            savedTold[officer] = true
            sendTo(officer, { kind = Schema.messageKind.claimSaved, ids = ids })
        end
    end
end

local function ackSaved(name)
    for _, c in ipairs(officerClaims:openSaved()) do
        if (not name or c.from == name) and not savedAcked[c.id] then
            local _, online = GBA.rosterEntry(c.from)
            if online then
                savedAcked[c.id] = true
                ackClaim(c.from, c, true)
            end
        end
    end
end

-- The officer's decisions. Awarding at the mailbox calls ns.awardClaim once the reward mail
-- has actually gone; declining only records, because the officer returns the items by hand.
local function decide(id, state)
    if not GBA.mayAct("offer") then return nil, "you may not decide claims" end
    local record, notice = officerClaims:decide(id, state, GBA.now())
    if not record then return nil, notice end
    signAndSpread(notice)
    -- A guild quest's evidence joins the guild's analytics once the claim is accepted, credited
    -- to the claimant (hard-quest spec, Part 3); a declined claim's is dropped.
    local ev = record.evidence
    record.evidence = nil
    if state == Reward.state.settled and type(ev) == "table" and ns.acceptClaim then
        pcall(ns.acceptClaim, { facts = ev.facts, sessions = ev.sessions, from = record.from, claimant = record.from })
    end
    -- A session this claim sent may open now: data joins once its claim is accepted (Vault, N2).
    if state == Reward.state.settled and ns.Vault and ns.Vault.openAccepted then pcall(ns.Vault.openAccepted) end
    return record
end

function ns.awardClaim(id) return decide(id, Reward.state.settled) end
function ns.declineClaim(id) return decide(id, Reward.state.declined) end

-- One more claim of an offer for one player, for a repeatable bounty.
function ns.requeueClaim(rewardID, name)
    if not GBA.mayAct("offer") then return nil, "you may not requeue claims" end
    local notice, err = officerClaims:requeue(rewardID, name, GBA.now())
    if not notice then return nil, err end
    signAndSpread(notice)
    return notice
end

-- Check-ins, on events rather than a clock (the user's rule, 2026-09-24: guild logins and zone
-- changes). At this officer's login and zone change: everything owed to everyone online. When a
-- guild member comes online: what is owed to them, and, if they are an officer, the decisions and
-- held claims they need. A delivery nobody acknowledges is retried a few times, backing off.
local function checkInAll()
    tellEveryone()
    shareAll()
    tellSaved()
    ackSaved()
    ns.passOnHeld()
end

function ns.checkInWith(name)
    name = GBA.Net.short(name)
    if not name then return end
    ns.tellClaimant(name)
    ackSaved(name)
    if GBA.Authority.may("officer", { name = name, rankIndex = GBA.rosterRankOf(name) }) then
        -- Just back online: whatever they were told before, they may have missed since.
        deliveredTold[name] = nil
        for _, sent in pairs(sharedWith) do sent[name] = nil end
        savedTold[name] = nil
        shareAll()
        tellSaved({ name })
        ns.forgetPosterHas(name)
        ns.passOnHeld(name)
    end
end
ns.checkInAll = checkInAll

local ticker = CreateFrame("Frame")
ticker:RegisterEvent("PLAYER_LOGIN")
ticker:SetScript("OnEvent", function()
    C_Timer.After(15, function()
        officerClaims:prune(GBA.now(), function(rewardID) return catalog:live(rewardID) ~= nil end, {
            -- Known here, and removed by its poster (DEC-3). Missing is not ended, and neither is
            -- expired: what expiry does to claims is still an open question (DQ-18).
            ended = function(rewardID)
                local known = catalog:get(rewardID) or (ns.rewardCatalog and ns.rewardCatalog:get(rewardID))
                return known ~= nil and known.retracted == true
            end,
            inGuild = GBA.inGuild,
        })
        -- Offers posted before this officer had a signature key: signed now, so any officer
        -- can pass them along.
        signOwn(false)
        checkInAll()
    end)
end)

-- Dev-build stand-ins for the mailbox buttons, by the number /gba claims shows.
local function byNumber(arg)
    local which = tonumber((arg or ""):match("%d+"))
    return which and officerClaims:all()[which]
end

local function report(ok, err, done)
    GBA.Print(ok and done or ("|cffff4040" .. tostring(err) .. "|r"))
end

