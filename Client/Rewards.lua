-- The player's side of the reward layer: receive what officers offer, and keep it.
--
-- This is the first thing that travels officer -> player. Everything until now went the
-- other way, which means this is also the first real test of the addon channel between two
-- clients - the one piece of the transport that has never been verified.
--
-- A reward is small. One fits in a single message where a session takes hundreds, so if
-- the channel works at all it works here, and a failure is a failure of the channel rather
-- than of chunking or throttling.
local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

local Codec, Schema, Reward, Resolve = GBA.Codec, GBA.Schema, GBA.Reward, GBA.Resolve

local catalog = Reward.Catalog.new()
ns.rewardCatalog = catalog

-- What this character has claimed. Saved with the rest of the character's data by
-- Status.lua; see ClaimLog for what an entry holds and why.
local myClaims = GBA.ClaimLog.new()
ns.myClaims = myClaims

-- Officers asked for the current offers who have not answered yet (see ns.askRewards).
local awaiting = {}

local seen = { offers = 0, refused = 0, lastFrom = nil }

-- Whoever sent this, as the SERVER reports them.
--
-- This is the one identity in the whole design that does not have to be taken on trust.
-- Everything inside a payload was written by a client and can say anything; the sender on
-- a CHAT_MSG_ADDON event comes from the server. So "is this person actually an officer"
-- is genuinely checkable, where "does this payload claim to be from an officer" would not
-- be worth asking.
local function mayOffer(sender)
    -- Testing shortcut, deliberately loud. See ns.config.trustAnyOffer.
    if ns.config and ns.config.trustAnyOffer then
        return true, "rank not checked"
    end

    -- The game's roster first, the source every other permission check uses: GRM's copy can be
    -- stale, and a stale rank here could keep a demoted officer's offers in (docs/fix-plan.md,
    -- T5). GRM only while the roster has no answer, and its 99 means it does not know either.
    local rankIndex = GBA.rosterRankOf(sender)
    if type(rankIndex) ~= "number" then
        local _, grm = GBA.spokes:call("GRM", "getRank", sender)
        if type(grm) == "number" and grm < 99 then rankIndex = grm end
    end

    -- An unknown rank is refused inside Authority, loudly rather than silently. The rule
    -- itself lives there so it changes in one place when signed roles replace rank.
    return GBA.Authority.may("offer", { rankIndex = rankIndex, name = sender })
end

-- Blizzard's roster, for guilds not running GRM. Kept under its old name for callers;
-- the scan itself moved to Core so the Guild addon checks claims with the same code.
ns.blizzardRankOf = GBA.rosterRankOf

-- Signed offers --------------------------------------------------------------------------
--
-- An offer signed with a key the guild master stamped for its issuer is taken from anyone who
-- passes it along: that is how a member gets an offline officer's offer from whichever officer
-- is online. A signature that fails is refused outright, never retried under the unsigned rule,
-- because a bad signature means the offer was changed. An offer with no signature, or from an
-- issuer with no stamped key, is taken only straight from its issuer, as before signatures.
-- Spec: docs/superpowers/specs/2026-09-24-officer-signature-keys-design.md.
--
-- A check costs about a tenth of a second in the game's Lua, so checks are queued and run one
-- per frame, and each offer revision is checked once: the result is remembered by offer,
-- revision and signature, and saved with the character's data by Status.lua.
local OfferSig = GBA.OfferSig
local verified = {}                 -- vkey -> true | false
local queued = {}                   -- vkey -> true while its check is running

-- What a check is remembered by: the offer revision and signature, and the key it was checked
-- against, so a key the guild master restamps is checked afresh rather than trusted from memory.
local function vkey(reward)
    return OfferSig.cacheKey(reward) .. "#" .. tostring(GBA.roles:keyOf(reward.issuer))
end

function ns.offerVerified(reward)
    return type(reward) == "table" and reward.sig ~= nil and verified[vkey(reward)] == true
end

-- Only results for offers still held are kept.
function ns.exportVerified()
    local out = {}
    for _, reward in ipairs(catalog:all()) do
        if reward.sig then
            local key = vkey(reward)
            if verified[key] ~= nil then out[key] = verified[key] end
        end
    end
    return out
end

function ns.importVerified(saved)
    if type(saved) ~= "table" then return end
    for key, ok in pairs(saved) do
        if type(key) == "string" and type(ok) == "boolean" then verified[key] = ok end
    end
end

-- "good", "bad" or "wait" for a signed offer from an issuer with a stamped key; nil when the
-- unsigned rule applies.
local function signatureVerdict(reward)
    if not reward.sig then return nil end
    if not GBA.roles:keyOf(reward.issuer) then return nil end
    local result = verified[vkey(reward)]
    if result == nil then return "wait" end
    return result and "good" or "bad"
end

local function newCounts() return { added = 0, updated = 0, removed = 0 } end

local function report(counts, sender)
    if counts.added > 0 or counts.updated > 0 or counts.removed > 0 then
        -- The tab is where these are read, so it is redrawn here rather than waiting for
        -- the player to click away and back.
        if ns.rewardsTab then ns.rewardsTab.setCount(catalog:count()) end
        if ns.RewardsPanel and ns.RewardsPanel.built() then ns.RewardsPanel.refresh() end
    end
    if counts.added > 0 or counts.updated > 0 then
        GBA.Print(string.format("|cff40ff40%s offered %d reward(s)|r%s",
            tostring(sender), counts.added + counts.updated,
            counts.updated > 0 and string.format(" (%d already known)", counts.updated) or ""))
    end
    if counts.removed > 0 then
        GBA.Print(string.format("|cffffcc00%s removed %d reward(s)|r", tostring(sender), counts.removed))
    end
end

local function refuse(why)
    seen.refused = seen.refused + 1
    GBA.Print("|cffffcc00dropped a reward:|r " .. tostring(why))
end

local take

-- Signed offers waiting for their issuer's stamped key: id -> { reward, sender }. Kept until a
-- role list arrives; one that still has no key then is dropped with the reason.
local waitingForKey = {}
local MAX_WAITING = 40

local function hold(reward, sender)
    local count = 0
    for _ in pairs(waitingForKey) do count = count + 1 end
    if count >= MAX_WAITING and not waitingForKey[reward.id] then
        return refuse("too many signed offers waiting for keys; ask again once the role list is in")
    end
    waitingForKey[reward.id] = { reward = reward, sender = sender }
end

GBA.onRoleList(function()
    local held = waitingForKey
    waitingForKey = {}
    local counts, sender = { added = 0, updated = 0, removed = 0 }, nil
    for _, item in pairs(held) do
        sender = item.sender
        if GBA.roles:keyOf(item.reward.issuer) then
            take(item.reward, item.sender, counts)
        else
            refuse(string.format("\"%s\" is signed by %s, whose key the guild master has not stamped",
                tostring(item.reward.title), tostring(item.reward.issuer)))
        end
    end
    if sender then
        counts.sealed = true
        if (counts.pending or 0) == 0 then report(counts, sender) end
    end
end)

-- Takes one validated offer, or refuses it. Returns nothing; counts what it changed. A signature
-- not yet checked is checked as a job (GBA.edJob, spread across frames) and the offer taken when
-- it finishes; counts.pending says how many are still out, and the batch reports when the last
-- one lands.
take = function(reward, sender, counts)
    local verdict = signatureVerdict(reward)
    if verdict == "wait" then
        local key = vkey(reward)
        if queued[key] then return end
        queued[key] = true
        counts.pending = (counts.pending or 0) + 1
        local issuerKey = GBA.roles:keyOf(reward.issuer)
        GBA.edJob(function() return OfferSig.verify(reward, issuerKey) end, function(ok)
            queued[key] = nil
            verified[key] = ok
            take(reward, sender, counts)
            counts.pending = counts.pending - 1
            if counts.pending == 0 and counts.sealed then report(counts, sender) end
        end)
        return
    elseif verdict == "bad" then
        return refuse(string.format("\"%s\" is signed, but not with the key the guild master stamped for %s",
            tostring(reward.title), tostring(reward.issuer)))
    elseif verdict == "good" then
        -- Proven to be the issuer's. Whether they may publish is still the role list's say.
        if not GBA.Authority.may("offer", { name = GBA.Net.short(reward.issuer), rankIndex = GBA.rosterRankOf(reward.issuer) }) then
            return refuse(tostring(reward.issuer) .. " does not hold the publisher role")
        end
    else
        -- The unsigned rule. The issuer is where the claim is whispered and where items are
        -- mailed, so it has to be the character the server says sent this. The check applies
        -- even with trustAnyOffer on: that switch skips the rank check, not the identity check.
        if not Reward.issuerMatches(reward.issuer, sender) then
            -- Signed, passed along by another officer, and this client does not know the
            -- issuer's stamped key yet: usually because the role list is still on its way at
            -- login. Held, and taken the moment a list brings the key (see onRoleList below).
            if reward.sig then
                return hold(reward, sender)
            end
            return refuse(string.format("issued by %s but sent by %s, and not signed",
                tostring(reward.issuer), tostring(sender)))
        end
        if not mayOffer(sender) then
            return refuse(tostring(sender) .. " may not publish offers")
        end
    end

    -- Every extra reader a reward names must hold the reader role, or the reward is refused:
    -- otherwise anyone allowed to publish could name themselves a friend to read every
    -- player's data. With no role list yet, rank decides, as for everything else.
    for _, name in ipairs(reward.readers or {}) do
        if not GBA.Authority.may("reader", { name = name, rankIndex = GBA.rosterRankOf(name) }) then
            return refuse("names " .. name .. " as a reader, who does not hold the reader role")
        end
    end

    local wasLive = catalog:live(reward.id) ~= nil
    local _, existed, stale = catalog:put(reward)
    -- An older copy than the one held changed nothing, so it is not news. A removal is held
    -- like any revision; it only counts if it took something down.
    if stale then
        return
    elseif reward.retracted then
        if wasLive and not catalog:live(reward.id) then counts.removed = counts.removed + 1 end
    elseif existed then
        counts.updated = counts.updated + 1
    else
        counts.added = counts.added + 1
    end
end

GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end

    local kind = payload.kind
    -- Facts are the guild addon's business; this handler only wants offers. Both addons
    -- listen on the one prefix, so each has to ignore what is not addressed to it.
    if kind ~= Schema.messageKind.reward and kind ~= Schema.messageKind.rewardCatalog then
        return
    end
    -- An answer, whatever it holds: this officer is not silent.
    awaiting[GBA.Net.short(sender)] = nil

    local sent = payload.envelope and payload.envelope.schemaVersion
    if sent ~= Schema.VERSION then
        return GBA.Print(string.format(
            "|cffffcc00ignored an offer from %s: schema v%s, this client reads v%d|r",
            tostring(sender), tostring(sent), Schema.VERSION))
    end

    -- Offers come from officers: their own, or other officers' signed ones passed along.
    local allowed, why = mayOffer(sender)
    -- Said every time rather than once at login: a check that is off should never be
    -- quietly off, and this is the only thing standing between a member and an offer.
    if allowed and why == "rank not checked" then
        GBA.Print("|cffff8800trusting any offer: rank checking is OFF (/gba trustoffers off)|r")
    end
    if not allowed and not GBA.Authority.may("officer", { name = GBA.Net.short(sender), rankIndex = GBA.rosterRankOf(sender) }) then
        seen.refused = seen.refused + 1
        return GBA.Print(string.format(
            "|cffff4040refused an offer from %s|r: %s", tostring(sender), tostring(why)))
    end

    local counts = newCounts()
    for _, fields in ipairs(payload.rewards or {}) do
        -- Revalidated rather than trusted. This was written by somebody else's client.
        local reward, err = Reward.new(fields)
        if reward then
            take(reward, sender, counts)
        else
            GBA.Print("|cffffcc00dropped a malformed reward:|r " .. tostring(err))
        end
    end

    seen.offers = seen.offers + 1
    seen.lastFrom = sender
    -- With signatures still being checked, the report waits for the last one.
    counts.sealed = true
    if (counts.pending or 0) == 0 then report(counts, sender) end
end)

-- An officer's decision on one of this character's claims, or a requeue of an offer.
--
-- Taken only from the officer the claim went to: the offer's issuer, as the server reports
-- the sender. Acknowledged every time, even when it changes nothing here, so the officer stops
-- resending; the acknowledgement names only the notice, never anything about this character.
local STATE_SAID = {
    [Reward.state.settled] = "|cff40ff40awarded|r",
    [Reward.state.declined] = "|cffffcc00declined|r",
}

GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" or payload.kind ~= Schema.messageKind.claimNotice then return end
    if not payload.envelope or payload.envelope.schemaVersion ~= Schema.VERSION then return end
    local notice = payload.notice
    if type(notice) ~= "table" or notice.rewardID == nil then return end

    local function ack()
        local encodedAck = Codec.encode({
            kind = Schema.messageKind.claimNoticeAck,
            envelope = { schemaVersion = Schema.VERSION },
            key = notice.key,
        }, Codec.MODE_CHANNEL)
        if encodedAck then GBA.Channel.send(encodedAck, "WHISPER", sender) end
    end

    local entry = myClaims:latest(notice.rewardID)
    -- A decision on a claim this character never made (saved data lost, say) changes nothing,
    -- but is still acknowledged so the officers stop sending it.
    if not entry then return ack() end
    local poster = entry.issuer and (entry.issuer:match("^([^%-]+)") or entry.issuer)

    local function apply(decider)
        -- The same decision can arrive from more than one officer; it is said once.
        local already = (notice.kind == "requeue" and entry.requeued)
            or (notice.kind == "state" and entry.at == notice.at and entry.state == notice.state)
        local changed = myClaims:apply(notice, GBA.now())
        if changed and not already then
            if notice.kind == "requeue" then
                GBA.Print(string.format("%s lets you claim \"%s\" again", decider, changed.title))
            else
                GBA.Print(string.format("%s %s your claim for \"%s\"", decider,
                    STATE_SAID[changed.state] or "answered", changed.title))
            end
            if ns.RewardsPanel and ns.RewardsPanel.built() then ns.RewardsPanel.refresh() end
        end
        ack()
    end

    -- Straight from the officer the claim went to, as before signed decisions.
    if Reward.issuerMatches(entry.issuer, sender) then return apply(GBA.Net.short(sender)) end

    -- Carried by another officer, or made by another decider: taken only with the signature of
    -- one of the offer's deciders (its poster, or whoever the poster named, DEC-4), checked
    -- against the key the guild master stamped for them, and only while that decider is still a
    -- publisher in the guild. The carrier cannot change a word of it.
    local offer = catalog:get(notice.rewardID)
    local byDecider = type(notice.by) == "string" and (offer and Reward.isDecider(offer, notice.by)
        or Reward.issuerMatches(entry.issuer, notice.by))
    local stillMay = byDecider and GBA.Authority.may("offer",
        { name = GBA.Net.short(notice.by), rankIndex = GBA.rosterRankOf(notice.by) })
    if not notice.sig or not byDecider or not stillMay
        or GBA.Net.short(notice.to or "") ~= UnitName("player") then
        return GBA.Print("|cffff4040ignored a claim decision from " .. tostring(sender)
            .. "|r: it is not signed by one of the deciders of the offer " .. tostring(poster) .. " posted")
    end
    local key = GBA.roles:keyOf(notice.by)
    if not key then return end          -- not stamped here yet; it will be sent again
    GBA.edJob(function() return OfferSig.verifyNotice(notice, key) end, function(ok)
        if not ok then
            return GBA.Print("|cffff4040refused a claim decision carried by " .. tostring(sender)
                .. "|r: its signature is not " .. GBA.Net.short(notice.by) .. "'s")
        end
        apply(GBA.Net.short(notice.by))
    end)
end)

-- Who this character is, for a claim to be attributed to.
function ns.observerKey()
    return GBA.Provenance.observerKey({
        name = UnitName("player"),
        realm = GetRealmName and GetRealmName() or nil,
    })
end

-- Sends a claim. Returns true, or nil and a reason.
--
-- The attachment is gathered HERE rather than sent wholesale and filtered by the receiver.
-- Sending everything and trusting the other end to discard the rest is not a privacy
-- boundary; what is not sent is the only thing that cannot be read.
-- Where a claim message goes right now: the officer who posted the offer when they are online,
-- otherwise any online officer, who holds it for the poster and passes it on when they log in.
-- The officers share it; the player need not be online by then. Decided by the user, 2026-09-24.
-- nil when no officer at all is online: the claim then waits here and is sent again later.
-- With the poster offline, a decider they named comes next, since they can act on it (DEC-4).
local function claimTarget(issuer, rewardID)
    local poster = type(issuer) == "string" and (issuer:match("^([^%-]+)") or issuer) or nil
    if poster then
        local _, online = GBA.rosterEntry(poster)
        if online then return poster end
    end
    local offer = rewardID ~= nil and catalog:get(rewardID)
    for _, name in ipairs(offer and Reward.deciderList(offer) or {}) do
        local _, online = GBA.rosterEntry(name)
        if online then return name end
    end
    return GBA.onlineOfficers()[1]
end

-- Sends one claim message to `target`. Returns parts and bytes, or nil and why.
local function sendClaimMessage(claim, target)
    local payload = {
        kind = Schema.messageKind.rewardClaim,
        envelope = GBA.Provenance.build(
            GBA.Provenance.readEnvironment(GBA.version, Schema.VERSION),
            GBA.spokes:versions()),
        claim = claim,
    }
    local encoded = Codec.encode(payload, Codec.MODE_CHANNEL)
    if not encoded then return nil, "could not encode the claim" end
    local parts, seconds = GBA.Channel.send(encoded, "WHISPER", target)
    if not parts then return nil, tostring(seconds) end
    return parts, #encoded
end

function ns.sendClaim(state)
    local reward = state.reward
    if not reward then return nil, "pick a reward first" end

    local who = ns.observerKey()
    if not who then return nil, "cannot tell who you are; try /reload" end

    -- Addressed to an officer, never to the guild. A claim can carry the player's telemetry
    -- reference, and a broadcast hands that to every member running the Guild addon.
    if not reward.issuer then return nil, "that reward has no issuer to send the claim to" end

    local claim, err = Reward.claim({
        rewardID = reward.id,
        from = who,
        sending = state.sending,
        note = state.note,
        attach = reward.attach,
        sessionID = state.sessionID,
        transferID = state.transferID,
        revision = reward.revision,
        -- A guild quest's turn-in carries the facts that counted, for the officer's addon to
        -- recount (hard-quest spec, Part 3). Gathered now, before the quest leaves the log.
        evidence = reward.hardID and ns.questEvidence and ns.questEvidence(reward.hardID) or nil,
        at = GBA.now(),
    })
    if not claim then return nil, err end

    -- The data itself never travels in the claim. It was locked when Claim was pressed and
    -- goes by the secure transport, readable only by the officers the reward names; the
    -- claim only carries its id, so the officer can match the two.

    -- Recorded now, before sending: the mail has already gone, so this IS a claim whether or
    -- not an officer hears about it this minute. Undelivered until an officer confirms it.
    myClaims:record({
        rewardID = reward.id, title = reward.title, issuer = reward.issuer,
        revision = reward.revision, at = claim.at, sending = claim.sending, note = claim.note,
        attach = claim.attach, transferID = claim.transferID, sessionID = claim.sessionID,
        delivered = false,
        -- The offer's other deciders, each still owed a letter about this claim (DEC-5).
        lettersDue = state.lettersDue,
        evidence = claim.evidence,
    })
    -- A guild quest's claim is its turn-in: it leaves the quest log for good (ZoneQuests.lua).
    if reward.hardID and ns.hardLog then ns.hardLog:turnIn(reward.hardID, claim.at) end

    local poster = reward.issuer:match("^([^%-]+)") or reward.issuer
    local target = claimTarget(reward.issuer, reward.id)
    if not target then
        GBA.Print(string.format("|cff40ff40claimed \"%s\"|r; no officer is online, so the claim goes to the first one who is",
            reward.title))
    else
        local parts, bytes = sendClaimMessage(claim, target)
        ns.retryClaims()
        if not parts then
            GBA.Print("|cffffcc00claimed, but the claim message did not go yet:|r " .. tostring(bytes))
        elseif target == poster then
            GBA.Print(string.format("|cff40ff40claimed \"%s\"|r to %s in %d message(s), %.1f KB",
                reward.title, target, parts, bytes / 1024))
        else
            GBA.Print(string.format("|cff40ff40claimed \"%s\"|r; %s is offline, so %s holds it for them",
                reward.title, poster, target))
        end
    end
    if claim.attach == Reward.attach.none then
        GBA.Print("  no gameplay data was attached")
    elseif claim.transferID then
        GBA.Print("  your data follows by the secure transport as session " .. claim.transferID)
    end
    return true
end

-- Claims no officer has on disk yet, sent again to whoever is online, on check-ins (login, a
-- zone change, an officer coming online): an officer's "have it" is only memory until they reload
-- (DEC-6). With unheard, only those no officer has answered at all: the quick retries, 30, 60
-- and 120 seconds after sending. Cheap when there are none.
function ns.resendClaims(unheard)
    local waiting = unheard and myClaims:undelivered() or myClaims:unsaved()
    if #waiting == 0 then return 0 end
    local who = ns.observerKey()
    if not who then return 0 end
    local sent = 0
    for _, entry in ipairs(waiting) do
        -- An offer its poster removed takes the addon's part in its claims with it: what
        -- happens to the mail is the poster's call, by hand (docs/fix-plan.md, DEC-3). Offering
        -- the claim again would only be refused, at every check-in, for good.
        local offer = catalog:get(entry.rewardID)
        local withdrawn = offer and offer.retracted
        local target = not withdrawn and claimTarget(entry.issuer, entry.rewardID)
        local claim = target and Reward.claim({
            rewardID = entry.rewardID, from = who, sending = entry.sending, note = entry.note,
            attach = entry.attach, sessionID = entry.sessionID, transferID = entry.transferID,
            at = entry.at, revision = entry.revision, evidence = entry.evidence,
        })
        if claim and sendClaimMessage(claim, target) then sent = sent + 1 end
    end
    return sent
end

-- An officer confirms holding a claim: the poster themselves, or another officer holding it
-- for them. Taken only from someone the officer role applies to.
GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" or payload.kind ~= Schema.messageKind.claimAck then return end
    if not payload.envelope or payload.envelope.schemaVersion ~= Schema.VERSION then return end
    local who = GBA.Net.short(sender)
    if not GBA.Authority.may("officer", { name = who, rankIndex = GBA.rosterRankOf(sender) })
        and not GBA.Authority.may("offer", { name = who, rankIndex = GBA.rosterRankOf(sender) }) then return end
    -- "Saved" means some officer has it on disk (docs/fix-plan.md, DEC-6); until then it is
    -- offered again at every check-in.
    local entry, changed, nowSaved = myClaims:markDelivered(payload.rewardID, payload.at, payload.saved == true)
    if entry and changed then
        local poster = entry.issuer and (entry.issuer:match("^([^%-]+)") or entry.issuer)
        if poster == who then
            GBA.Print(string.format("%s has your claim for \"%s\"", who, entry.title))
        else
            GBA.Print(string.format("%s is holding your claim for \"%s\" until %s is online", who, entry.title, tostring(poster)))
        end
    end
    if entry and nowSaved then
        GBA.Print(string.format("your claim for \"%s\" is saved by the officers", entry.title))
    end
    if entry and (changed or nowSaved) and ns.RewardsPanel and ns.RewardsPanel.built() then
        ns.RewardsPanel.refresh()
    end
end)

-- An officer could not take a claim, and said why (docs/fix-plan.md, E4). Said once per claim
-- and reason, and shown on the claim's status line; the claim is still offered at check-ins,
-- because another officer may take it. The envelope is not checked: a version mismatch is one of
-- the reasons this exists to tell.
local refusals = {}          -- "rewardID@at" -> the latest reason, this session
function ns.claimRefusal(entry)
    return entry and refusals[tostring(entry.rewardID) .. "@" .. tostring(entry.at)] or nil
end

GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" or payload.kind ~= Schema.messageKind.claimRefused then return end
    local who = GBA.Net.short(sender)
    if GBA.rosterRankOf(sender) == nil then return end
    local entry = payload.rewardID ~= nil and myClaims:latest(payload.rewardID)
    if not entry or entry.at ~= payload.at or type(payload.reason) ~= "string" then return end
    local reason = payload.reason:sub(1, 200)
    local key = tostring(entry.rewardID) .. "@" .. tostring(entry.at)
    if refusals[key] == reason then return end
    refusals[key] = reason
    GBA.Print(string.format("|cffffcc00%s could not take your claim for \"%s\":|r %s", who, entry.title, reason))
    if ns.RewardsPanel and ns.RewardsPanel.built() then ns.RewardsPanel.refresh() end
end)

-- A claim not yet confirmed: tried again 30, 60 and 120 seconds later, and no more until the next
-- check-in. No clock of its own.
local RESEND_AGAIN = { 30, 60, 120 }
local resendTry = nil
function ns.retryClaims(try)
    try = try or 1
    if not RESEND_AGAIN[try] or resendTry == try then return end
    resendTry = try
    C_Timer.After(RESEND_AGAIN[try], function()
        if resendTry ~= try then return end
        resendTry = nil
        if #myClaims:undelivered() > 0 then
            ns.resendClaims(true)
            ns.retryClaims(try + 1)
        end
    end)
end

local resender = CreateFrame("Frame")
resender:RegisterEvent("PLAYER_ENTERING_WORLD")
resender:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    C_Timer.After(20, function()
        if ns.resendClaims() > 0 then ns.retryClaims() end
    end)
end)

-- The channel queues nothing, so a reward broadcast while you were offline never reaches
-- you. Asking is how somebody who missed it catches up.
-- Asks each online officer for the rewards on offer. Returns how many were asked.
--
-- Whispered, one officer at a time, never sent to the guild channel: a rank muted in guild
-- chat cannot send there, and the server drops the message without a word, so a member like
-- that could never catch up (found in game 2026-09-23). Officers answer by whisper too.
function ns.askRewards(quiet)
    local officers = GBA.onlineOfficers()
    if #officers == 0 then
        if not quiet then GBA.Print("no officer is online to ask for the current rewards") end
        return 0
    end
    local encoded = Codec.encode({
        kind = Schema.messageKind.catalogQuery,
        envelope = { schemaVersion = Schema.VERSION },
    }, Codec.MODE_CHANNEL)
    if not encoded then return 0 end
    for _, name in ipairs(officers) do
        GBA.Channel.send(encoded, "WHISPER", name)
        awaiting[name] = true
    end
    if not quiet then GBA.Print("asked " .. table.concat(officers, ", ") .. " for the current rewards") end
    -- An officer who never answers is named, rather than the list just staying the same.
    C_Timer.After(10, function()
        local silent = {}
        for _, name in ipairs(officers) do
            if awaiting[name] then silent[#silent + 1] = name; awaiting[name] = nil end
        end
        if #silent > 0 and not quiet then
            GBA.Print("|cffffcc00no answer from " .. table.concat(silent, ", ")
                .. ". If this keeps happening, both of you /reload so you run the same version.|r")
        end
    end)
    return #officers
end

-- The offer handshake (Summary.lua; the officer's half is in the Guild addon's Offers.lua).
--
-- Asking is cheap and always fine; being sent what nobody asked for is not. A check is a summary
-- of the offers held, per poster a count and a digest, a few dozen bytes. The officer answers
-- with its own summary ("I'm checking too") plus, only where the digests differ, its list of ids
-- and revisions. Then exactly the missing offers are asked for, each from one officer.
--
-- Before and after:
-- - Before: a check nobody answers is sent again after 10, 20 and 40 seconds; after that, a
--   check that went to one officer goes to another.
-- - After: 10 seconds after the answer, the digests are compared again. Where that officer still
--   holds something newer (a list or an offer lost on the way), another round, up to three.
--
-- Logins check with every officer online. A zone change, the mailbox and Refresh check with one,
-- taking turns, since those come often and one officer is enough to catch up from.
local Summary = GBA.Summary
local WANT_GAP, VERIFY_AFTER, MAX_ROUNDS = 20, 10, 3
local RETRY = { 10, 20, 40 }
local checks = {}          -- officer -> the check waiting on them
local wanted = {}          -- offer id -> when it was last asked for, so two lists do not ask twice
local turn = 0

-- What this client can vouch for: an officer's client, what it can pass along; a member's, all
-- it holds.
local function mySummary()
    return Summary.of(ns.relayable and ns.relayable() or catalog:all())
end

local function sendSummary(to, reply)
    local encoded = Codec.encode({
        kind = Schema.messageKind.offerSummary,
        envelope = { schemaVersion = Schema.VERSION },
        summary = mySummary(),
        reply = reply or nil,
    }, Codec.MODE_CHANNEL)
    -- A newer summary for the same officer replaces one still waiting.
    if encoded then GBA.Channel.send(encoded, "WHISPER", to, { lane = "control", kind = "offerSummary", key = "offerSummary" }) end
end
ns.sendOfferSummary = sendSummary

-- Whether an officer's summary shows something this client lacks or holds older: a poster whose
-- digest differs and of whom the officer holds at least as many offers. (Holding more than the
-- officer is not being behind: a member keeps offers an officer cannot pass along.)
local function behind(theirs)
    local mine = mySummary()
    for author, t in pairs(type(theirs) == "table" and theirs or {}) do
        local m = mine[author]
        if type(t) == "table" and (not m or (t.d ~= m.d and (tonumber(t.n) or 0) >= m.n)) then return true end
    end
    return false
end

local function ask(name, c)
    c.tries = c.tries + 1
    c.token = c.token + 1
    local token = c.token
    sendSummary(name)
    C_Timer.After(RETRY[c.tries] or RETRY[#RETRY], function()
        if checks[name] ~= c or c.token ~= token then return end
        if RETRY[c.tries + 1] then return ask(name, c) end
        checks[name] = nil
        if not c.quiet then
            GBA.Print("|cffffcc00no answer from " .. name
                .. ". If this keeps happening, both of you /reload so you run the same version.|r")
        end
        if c.onSilent then c.onSilent(name) end
    end)
end

-- Checks with the officers named. opts: round (of the after-check), onSilent(name). Returns how
-- many were asked.
function ns.syncWith(names, quiet, opts)
    opts = opts or {}
    local me, asked = UnitName("player"), {}
    for _, name in ipairs(names) do
        name = GBA.Net.short(name)
        if name and name ~= me and not checks[name] then
            local c = { tries = 0, token = 0, round = opts.round or 1, quiet = quiet, onSilent = opts.onSilent }
            checks[name] = c
            ask(name, c)
            asked[#asked + 1] = name
        end
    end
    if #asked == 0 then
        if not quiet and #names == 0 then GBA.Print("no officer is online to ask for the current rewards") end
        return 0
    end
    if not quiet then GBA.Print("checking with " .. table.concat(asked, ", ") .. " for new or changed rewards") end
    return #asked
end

-- The officer's answer arrived: stop asking, and check again a moment later that nothing is
-- still missing.
local function answered(who, theirs)
    local c = checks[who]
    if not c then return end
    checks[who] = nil
    if c.round >= MAX_ROUNDS then return end
    C_Timer.After(VERIFY_AFTER, function()
        if behind(theirs) then ns.syncWith({ who }, true, { round = c.round + 1 }) end
    end)
end

local function otherOfficers()
    local me, out = UnitName("player"), {}
    for _, name in ipairs(GBA.onlineOfficers()) do
        name = GBA.Net.short(name)
        if name ~= me then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

-- everyone: every officer online (at login). Otherwise one, taking turns; if that one never
-- answers, the next. Returns how many were asked.
function ns.syncOffers(quiet, everyone)
    local officers = otherOfficers()
    if everyone or #officers <= 1 then return ns.syncWith(officers, quiet) end
    turn = turn + 1
    local first = officers[turn % #officers + 1]
    return ns.syncWith({ first }, quiet, { onSilent = function(silent)
        for _, name in ipairs(otherOfficers()) do
            if name ~= silent then return ns.syncWith({ name }, quiet) end
        end
    end })
end

-- Checks that happen on their own, with nothing for the player to do: when a guild member comes
-- online, and when this character changes zone.
--
-- A member coming online checks with the officers themselves (at their login). An officer
-- coming online is also checked with by every officer already online, a little later, so a check
-- lost at their login is repaired; and members hand them any session still waiting for an
-- officer. Seen two ways, since either may be missed: a guild roster update showing them online,
-- and the "has come online" line. The two come within moments of each other, so a name seen
-- again within 10 seconds is the same login; a later one is a new login and counts.
local CAME_GAP, CAME_DELAY, ZONE_GAP = 10, 20, 120
local cameAt, rosterOnline = {}, nil

local function cameOnline(name)
    name = GBA.Net.short(name)
    if not name or name == UnitName("player") then return end
    local now = GetTime()
    if cameAt[name] and now - cameAt[name] < CAME_GAP then return end
    cameAt[name] = now
    -- An officer's client checks in with anyone who comes online: the decisions it owes them,
    -- and, for an officer, the decisions and held claims they need.
    if ns.checkInWith then C_Timer.After(CAME_DELAY, function() ns.checkInWith(name) end) end
    if not GBA.Authority.may("officer", { name = name, rankIndex = GBA.rosterRankOf(name) }) then return end
    C_Timer.After(CAME_DELAY, function()
        -- An officer whose key this client lacks (new, and only shared once saved): ask for it.
        if ns.Outbox and ns.Outbox.directory and not ns.Outbox.directory():get(name) then ns.Outbox.requestKeys() end
        -- Sessions locked while no officer was online go to them now, and claims they have not
        -- confirmed.
        if ns.Outbox and ns.Outbox.flush then ns.Outbox.flush() end
        if ns.resendClaims() > 0 then ns.retryClaims() end
        if not ns.relayable then return end
        ns.syncWith({ name }, true)
        -- They may carry a session this officer has the key for but not the data.
        if ns.Vault and ns.Vault.fetchMissing then ns.Vault.fetchMissing() end
    end)
end

-- The game's own line, turned into a pattern: "|Hplayer:%s|h[%s]|h has come online." in English.
local onlinePattern
if type(ERR_FRIEND_ONLINE_SS) == "string" then
    onlinePattern = "^" .. ERR_FRIEND_ONLINE_SS:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", "(.-)") .. "$"
end

local lastZoneCheck = -math.huge
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("GUILD_ROSTER_UPDATE")
watcher:RegisterEvent("CHAT_MSG_SYSTEM")
watcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
watcher:SetScript("OnEvent", function(_, event, text)
    if event == "ZONE_CHANGED_NEW_AREA" then
        local now = GetTime()
        if now - lastZoneCheck < ZONE_GAP then return end
        lastZoneCheck = now
        if ns.Vault and ns.Vault.fetchMissing then ns.Vault.fetchMissing() end
        if ns.checkInAll then ns.checkInAll() end
        if ns.resendClaims() > 0 then ns.retryClaims() end
        return ns.syncOffers(true)
    elseif event == "CHAT_MSG_SYSTEM" then
        local name = onlinePattern and type(text) == "string" and text:match(onlinePattern)
        if name then cameOnline(name) end
    else
        -- Who is online now, against who was last time. The first roster seen only sets the
        -- starting point: everyone already online is not news.
        local now = {}
        for i = 1, (GetNumGuildMembers and GetNumGuildMembers() or 0) do
            local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if name and online then now[GBA.Net.short(name)] = true end
        end
        if rosterOnline then
            for name in pairs(now) do if not rosterOnline[name] then cameOnline(name) end end
        end
        rosterOnline = now
    end
end)

GBA.Channel.registerHandler(function(sender, encoded)
    local payload = Codec.decode(encoded)
    if type(payload) ~= "table" then return end
    local kind = payload.kind
    if kind ~= Schema.messageKind.offerSummary and kind ~= Schema.messageKind.offerList then return end
    if not payload.envelope or payload.envelope.schemaVersion ~= Schema.VERSION then return end
    local who = GBA.Net.short(sender)
    -- Lists and summaries are only taken from officers and publishers: they say what an officer
    -- holds, or what a poster has just posted.
    local fields = { name = who, rankIndex = GBA.rosterRankOf(sender) }
    if not (GBA.Authority.may("officer", fields) or GBA.Authority.may("offer", fields)) then return end

    if kind == Schema.messageKind.offerSummary then
        -- The officer heard us. Their lists, if anything differed, came just before this.
        if payload.reply then answered(who, payload.summary) end
        return
    end

    -- Each missing offer is asked for once, from whichever list showed it first: every officer
    -- answering a check may list the same offers.
    local now = GetTime()
    local want = {}
    for _, id in ipairs(Summary.wants(type(payload.entries) == "table" and payload.entries or {},
        function(id) return catalog:get(id) end)) do
        if not wanted[id] or now - wanted[id] > WANT_GAP then
            wanted[id] = now
            want[#want + 1] = id
        end
    end
    if #want == 0 then return end
    local ask = Codec.encode({
        kind = Schema.messageKind.offerWant,
        envelope = { schemaVersion = Schema.VERSION },
        ids = want,
    }, Codec.MODE_CHANNEL)
    if ask then GBA.Channel.send(ask, "WHISPER", sender, { lane = "control", kind = "offerWant" }) end
end)

-- Asked automatically after every login and reload, once the guild roster has arrived, so a
-- member who was offline when a reward went out still sees it.
-- And again whenever the mailbox opens, as Refresh does: it is where a member goes to claim, so
-- what they see there should be current. At most once a minute, so opening and closing it does
-- not ask again each time.
local MAILBOX_ASK_GAP = 60
local lastMailboxAsk = -math.huge
local asker = CreateFrame("Frame")
asker:RegisterEvent("PLAYER_ENTERING_WORLD")
asker:RegisterEvent("MAIL_SHOW")
asker:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SHOW" then
        local now = GetTime()
        if now - lastMailboxAsk < MAILBOX_ASK_GAP then return end
        lastMailboxAsk = now
        return ns.syncOffers(true)
    end
    if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
    -- After the role list is asked for (RoleSync, 12s), so it usually arrives first and signed
    -- offers other officers pass along can be checked at once. Held until it does otherwise.
    C_Timer.After(16, function() ns.syncOffers(true, true) end)
end)

-- Persistence is Status.lua's, not this file's.
--
-- It assigns GuildLedgerDB wholesale on PLAYER_LOGOUT, so a second writer on the
-- same event would either be clobbered or do the clobbering, depending on which frame the
-- client happened to call first. One writer, and this file only says what to write.
ns.restoreRewards = function(rewards, issued)
    local restored = catalog:load(rewards, issued)
    if restored > 0 then
        GBA.Print("restored " .. restored .. " offered reward(s)")
    end
    return restored
end
