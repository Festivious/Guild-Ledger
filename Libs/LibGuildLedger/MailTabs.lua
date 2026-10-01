-- The mailbox tab strip, shared.
--
-- Core's first VISIBLE widget, and it is here for one reason: the thing being shared is a
-- UI resource neither addon owns. MailFrame has two tabs of Blizzard's, and both
-- GuildLedger and GuildLedger_Guild want to add one. An officer running both has a
-- mailbox that needs four.
--
-- The previous arrangement could not do that. Player's MailTab computed its index as
-- (mail.numTabs or 2) + 1, which is right exactly once; and its tab's OnClick called its own
-- selectOurs directly rather than going through MailFrameTab_OnClick, so a second addon's
-- tab would never learn to stand down when the first was clicked. Two tabs, two panels, both
-- on screen.
--
-- So one owner, in the one place both addons already depend on. Core builds every tab, and
-- selecting any tab hides every other panel - Blizzard's two and ours alike.
--
-- What Core does NOT do is have an opinion about what a panel contains. `build` hands back a
-- host frame and the caller does as it likes inside it. No layout, no theming, no widgets.
-- That is what keeps a tab strip from turning into a UI framework living in Core.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local GBA = ns
if not GBA then return end

local MailTabs = {}
GBA.MailTabs = MailTabs

-- Blizzard's own tab template is not named anywhere we can read it, so these are tried in
-- turn rather than guessed at. All three exist in Classic; the first that builds wins.
local TEMPLATES = {
    "CharacterFrameTabButtonTemplate",
    "PanelTopTabButtonTemplate",
    "TabButtonTemplate",
}

-- Registered tabs, in registration order. Order here is tab order on the strip.
local registry = {}
local attached, failure, hooked = false, nil, false

local function makeTabButton(name, parent)
    for _, template in ipairs(TEMPLATES) do
        local ok, button = pcall(CreateFrame, "Button", name, parent, template)
        if ok and button then return button end
    end
    return nil
end

local function labelFor(entry)
    if entry.count and entry.count > 0 then
        return entry.label .. " (" .. entry.count .. ")"
    end
    return entry.label
end

local function resize(entry)
    if entry.button and PanelTemplates_TabResize then
        pcall(PanelTemplates_TabResize, entry.button, 0, nil, 36)
    end
end

-- Selection ---------------------------------------------------------------------

-- Wearing one of Blizzard's frames ------------------------------------------------
--
-- A tab does not get a background of its own. It WEARS one of Blizzard's - the Rewards list
-- wears the Inbox, the Offers composer wears Send Mail - and the difference between those
-- two frames is exactly the difference between the two panels that sit on them.
--
-- This replaced copying the art. Every previous attempt reproduced the background: cut a
-- sheet from the row block, anchor one to InboxFrameBg, copy the stationery halves texture by
-- texture. Each was wrong in its own way, and the last of them was wrong because InboxFrameBg
-- has art and no rectangle. The frame was there the whole time; the problem was that we were
-- hiding it and then painting a picture of it.
--
-- So the worn frame stays shown, with its parchment, its inset and its own art, and only the
-- furniture our panel sits on top of is put away.
-- Named, deliberately, rather than enumerated.
--
-- Asking SendMailFrame for its children and covering everything non-texture looked like the
-- tidier rule and broke the best thing on the frame: it caught Blizzard's scroll frame, whose
-- bar the claim view and the composer were both using. The named list never reached it -
-- SendMailScrollFrame has no rectangle on this client and is probably not that global at all
-- - so the bar kept working by never being found.
--
-- A list that misses things is the price of not covering the things worth keeping. The two
-- inset borders that still get covered are a known cost, to be walked back one at a time.
local WORN = {
    inbox = {
        frame = "InboxFrame",
        tab = 1,
        cover = { "InboxTitleText", "InboxCurrentPage",
                  "InboxPrevPageButton", "InboxNextPageButton", "OpenAllMail" },
    },
    sendmail = {
        frame = "SendMailFrame",
        tab = 2,
        -- The stationery is deliberately NOT covered: it is the page, and the page is the
        -- thing worth wearing.
        cover = { "SendMailTitleText", "SendMailNameEditBox", "SendMailSubjectEditBox",
                  -- MailEditBox has to go, and the stationery goes with it because those
                  -- textures are its children. That is fine: our own paper already draws
                  -- them, copied off the same files.
                  --
                  -- It is ONE body widget, and leaving it on screen meant the composer, the
                  -- claim view and a real outgoing mail were all showing the same text -
                  -- type an offer, open Send Mail, and the offer was sitting in a letter.
                  --
                  -- MailEditBoxScrollBar is NOT on this list any more, and that is the point
                  -- of the lender below. It used to be covered because there were two bars
                  -- on screen - /gba mailtree caught Blizzard's at 303,-79 and ours at
                  -- 308,-104, five units apart - and the one that got covered was the real
                  -- one. Now there is only ever one bar, because ours is Blizzard's,
                  -- borrowed. Covering it here would hide the thing we came for.
                  --
                  -- It does not need covering to stay out of Blizzard's letter either:
                  -- while it is not lent out it is still a child of MailEditBox, and alpha
                  -- multiplies down a frame's children, so covering the box covers the bar
                  -- inside it for free.
                  "MailEditBox",
                  "SendMailBodyEditBox", "SendMailScrollFrame",
                  "SendMailMailButton", "SendMailCancelButton",
                  "SendMailSendMoneyButton", "SendMailCODButton", "SendMailMoneyText",
                  "SendMailCostMoneyFrame", "SendMailMoneyFrame",
                  "SendMailMoneyGold", "SendMailMoneySilver", "SendMailMoneyCopper" },
        -- Left on screen but deaf: the money box at the bottom left is part of the page's look,
        -- and a click on it went to Blizzard's money row underneath.
        mute = { "SendMailMoneyInset", "SendMailMoneyBg" },
    },
}

for index = 1, 7 do
    WORN.inbox.cover[#WORN.inbox.cover + 1] = "MailItem" .. index
    -- And each row's icon button, by name: mouse is not inherited, so with only its row
    -- covered it went on taking clicks unseen, and a click on our offer's icon above it opened
    -- Blizzard's letter.
    WORN.inbox.cover[#WORN.inbox.cover + 1] = "MailItem" .. index .. "Button"
end
for index = 1, 12 do
    WORN.sendmail.cover[#WORN.sendmail.cover + 1] = "SendMailAttachment" .. index
end

-- Covered by ALPHA rather than hidden, and this is the load-bearing detail.
--
-- InboxFrame_Update runs on MAIL_INBOX_UPDATE and calls Show() on MailItem1..7. Hide() loses
-- that race: a letter arrives while the Rewards tab is up and Blizzard's rows appear over
-- ours. Show() does not touch alpha, so a covering made of alpha survives every update
-- Blizzard runs, without hooking anything of theirs.
--
-- Mouse goes off with it, because a button at alpha 0 still takes clicks, and an invisible
-- Open All swallowing a click on our page number is a bug nobody would ever guess at.
local covered = {}

local function cover(name)
    local region = _G[name]
    if not region or covered[name] then return end

    covered[name] = { alpha = region:GetAlpha() }
    region:SetAlpha(0)

    if region.EnableMouse and region.IsMouseEnabled then
        covered[name].mouse = region:IsMouseEnabled()
        region:EnableMouse(false)
    end
end

-- Mouse off, look untouched: for the pieces worth wearing that must not take clicks. The whole
-- of each frame, children included, because mouse is not inherited. Restored with the covered.
local function mute(frame)
    if not frame or not frame.EnableMouse or not frame.IsMouseEnabled then return end
    local key = frame
    if not covered[key] then
        covered[key] = { mouse = frame:IsMouseEnabled(), frame = frame }
        frame:EnableMouse(false)
    end
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if ok then for _, child in ipairs(children) do mute(child) end end
end

-- Asks the frame what it is made of, rather than naming every piece.
--
-- The named list missed something: a bordered box sat in the bottom-left corner of both
-- send-mail views, uncovered, because it is part of the money inset and nothing had thought
-- to name it. Guessing at what it is called would have been the usual mistake - so instead
-- the frame is asked for its children and regions, and anything it calls its own is covered.
--
-- `keep` is for the one piece worth wearing. On the inbox that is InboxFrameBg, the
-- parchment. On send mail nothing needs excepting, because the stationery is named
-- SendStationery and falls outside the pattern by itself.
local function uncoverAll()
    -- Blizzard's furniture is being given back, and the scroll bar is furniture. It goes
    -- home FIRST: every other path here restores an alpha, and an alpha restored on a box
    -- whose bar has been carried off leaves Blizzard's letter with nothing to scroll.
    if MailTabs.returnScrollBar then MailTabs.returnScrollBar() end

    for name, held in pairs(covered) do
        local region = held.frame or _G[name]
        if region then
            if held.alpha then region:SetAlpha(held.alpha) end
            if held.mouse ~= nil and region.EnableMouse then
                region:EnableMouse(held.mouse)
            end
        end
        covered[name] = nil
    end
end

-- Puts the chosen frame on and takes the other off.
--
-- Through Blizzard's OWN tab handler rather than by calling Show on the frame. Showing
-- SendMailFrame directly did not work: the inbox stayed underneath, because the mail frame
-- decides which of its two pages is up in MailFrameTab_OnClick and not in either page's
-- OnShow. Calling Show on the page skips everything the handler does around it.
--
-- So the tab is genuinely clicked, Blizzard sets its frame up exactly as it would for a
-- player, and only then is the furniture covered and our own tab marked selected again. The
-- whole switch happens inside one frame of animation, so what the eye sees is our panel on
-- the right background rather than a flicker through Blizzard's.
local switching = false

local function wearFrame(kind)
    local worn = WORN[kind] or WORN.inbox

    if worn.tab and type(_G.MailFrameTab_OnClick) == "function" then
        -- Guarded, because our own hook on this function is what stands tabs down - without
        -- the flag it would hear this click, uncover everything and hide the panel we are in
        -- the middle of showing.
        switching = true
        pcall(_G.MailFrameTab_OnClick, _G["MailFrameTab" .. worn.tab], worn.tab)
        switching = false
    else
        for name, spec in pairs(WORN) do
            local frame = _G[spec.frame]
            if frame and name ~= kind then frame:Hide() end
        end
        local frame = _G[worn.frame]
        if frame then frame:Show() end
    end

    -- Covered AFTER the switch: Blizzard's handler shows this page's furniture as part of
    -- setting it up, so covering first would simply be undone.
    for _, name in ipairs(worn.cover) do cover(name) end
    for _, name in ipairs(worn.mute or {}) do mute(_G[name]) end
end

-- Everything that is not the chosen tab goes away: Blizzard's furniture, and every panel any
-- addon registered. This is the part that could not live in one addon - Player cannot hide
-- a panel it has never heard of.
local function hideEverything(kind)
    -- OpenMailFrame is a window of its own rather than a tab's contents, so it goes whole.
    if _G.OpenMailFrame then _G.OpenMailFrame:Hide() end

    uncoverAll()
    wearFrame(kind)

    for _, entry in ipairs(registry) do
        if entry.panel and entry.panel:IsShown() then
            entry.panel:Hide()
            if entry.onHide then pcall(entry.onHide, entry.panel) end
        end
    end
end

local function selectTab(entry)
    -- Built on demand if the first attempt came to nothing. A panel that failed to build
    -- because its addon was not ready yet gets another chance rather than a dead tab.
    if not entry.panel and entry.build and _G.MailFrame then
        local ok, panel = pcall(entry.build, _G.MailFrame)
        if ok and panel then entry.panel = panel end
    end
    if not entry.panel then return end

    hideEverything(entry.wears)
    if PanelTemplates_SetTab then PanelTemplates_SetTab(_G.MailFrame, entry.index) end

    entry.panel:Show()
    if entry.onShow then pcall(entry.onShow, entry.panel) end
end

-- Blizzard switches tabs through its own handler, so ours stand down when it runs. Hooked
-- rather than replaced: replacing it would break the mailbox for every other addon that
-- also hooks it. One hook for the whole registry, however many tabs are on it.
local function hookBlizzard()
    if hooked or type(_G.MailFrameTab_OnClick) ~= "function" then return end
    hooksecurefunc("MailFrameTab_OnClick", function(_, clicked)
        -- Ours, mid-switch: not a player leaving for Blizzard's tab.
        if switching then return end

        -- Blizzard's own tab is back: it gets its furniture back with it.
        uncoverAll()
        for _, entry in ipairs(registry) do
            if entry.index ~= clicked and entry.panel and entry.panel:IsShown() then
                entry.panel:Hide()
                if entry.onHide then pcall(entry.onHide, entry.panel) end
            end
        end
    end)
    hooked = true
end

-- Attaching ---------------------------------------------------------------------

local function attachOne(mail, entry)
    if entry.button then return true end

    -- Read live rather than counted. Two addons registering means two tabs added, and the
    -- second has to see the first's.
    local index = (mail.numTabs or 2) + 1
    local name = "MailFrameTab" .. index

    local button = makeTabButton(name, mail)
    if not button then return false end
    _G[name] = button

    entry.button, entry.index = button, index
    button:SetID(index)
    button:SetText(labelFor(entry))

    local previous = _G["MailFrameTab" .. (index - 1)]
    if previous then
        -- The -15 overlap is Blizzard's own tab spacing, not a fudge: it is what the
        -- existing tabs use, and matching it is why an added tab does not look bolted on.
        button:SetPoint("LEFT", previous, "RIGHT", -15, 0)
    else
        button:SetPoint("BOTTOMLEFT", mail, "BOTTOMLEFT", 20, 40)
    end

    if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(mail, index) end
    if PanelTemplates_EnableTab then PanelTemplates_EnableTab(mail, index) end
    resize(entry)

    button:SetScript("OnClick", function()
        if PlaySound then
            PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841)
        end
        selectTab(entry)
    end)

    -- The panel is the caller's. Core only says where it lives and when it is on screen.
    local ok, panel = pcall(entry.build, mail)
    if ok and panel then
        entry.panel = panel
        panel:Hide()
    elseif not ok then
        -- Said out loud. A tab whose panel threw is a tab that does nothing when clicked,
        -- and silence there is the hardest kind of bug to find.
        GBA.Print("|cffff4040the " .. entry.label .. " tab failed to build:|r " .. tostring(panel))
    end

    return true
end

-- Idempotent, and public on purpose.
--
-- Core's own MAIL_SHOW handler is registered before either addon's, because Core loads
-- first, so relying on handler order WOULD work here. It is not relied on. That is exactly
-- the assumption ClaimFlow was written to stop depending on after it went wrong - which
-- handler runs first is decided by the TOC, not by anything either of them should depend
-- on. Asking is free and the answer is never early.
function MailTabs.attach()
    if attached then return true end

    local mail = _G.MailFrame
    if not mail or not PanelTemplates_SetNumTabs or not PanelTemplates_SetTab then
        failure = "this client's mail frame cannot take a tab"
        return false, failure
    end

    hookBlizzard()

    for _, entry in ipairs(registry) do
        if not attachOne(mail, entry) then
            failure = "no usable tab template on this client"
            return false, failure
        end
    end

    attached = true
    return true
end

-- Registering -------------------------------------------------------------------

-- A handle, so a caller can talk about ITS tab without reaching into the registry.
local function handleFor(entry)
    return {
        -- Counts arrive before the mailbox has ever been opened: offers are restored at
        -- login and the catalog notifies straight away. Stored, and applied when the tab
        -- is eventually built.
        setCount = function(count)
            entry.count = count
            if entry.button then
                entry.button:SetText(labelFor(entry))
                resize(entry)
            end
        end,
        select = function()
            if entry.panel then selectTab(entry) end
        end,

        -- Changed while the tab is up, because a tab is not always one shape.
        --
        -- The Rewards tab is the inbox until you open an offer, and then it is Send Mail -
        -- the claim view is a letter, and the frame it wants underneath it is the one a
        -- letter is written on. So which frame is worn follows the VIEW, not the tab.
        wear = function(kind)
            entry.wears = kind or entry.wears
            if entry.panel and entry.panel:IsShown() then
                uncoverAll()
                wearFrame(entry.wears)
                -- Wearing a frame means clicking its tab, and clicking its tab selects it.
                -- Ours is put back on top afterwards, or opening a claim would leave Send
                -- Mail looking like the tab the player is on.
                if PanelTemplates_SetTab then
                    PanelTemplates_SetTab(_G.MailFrame, entry.index)
                end
            end
        end,
        isSelected = function()
            return entry.panel ~= nil and entry.panel:IsShown()
        end,
        attached = function()
            return entry.button ~= nil
        end,
        panel = function()
            return entry.panel
        end,
    }
end

-- spec: { key, label, build(host) -> Frame, onShow(panel), onHide(panel) }
--
-- Registration is allowed at any time and costs nothing; attachment happens once, on the
-- first MAIL_SHOW, in registration order.
function MailTabs.register(spec)
    if type(spec) ~= "table" or type(spec.build) ~= "function" then return nil end

    -- Same key twice replaces rather than adds, so a reloaded addon does not grow the strip.
    for _, entry in ipairs(registry) do
        if entry.key == spec.key then
            entry.label, entry.build = spec.label or entry.label, spec.build
            entry.onShow, entry.onHide = spec.onShow, spec.onHide
            entry.wears = spec.wears or entry.wears
            return handleFor(entry)
        end
    end

    local entry = {
        key = spec.key or ("tab" .. (#registry + 1)),
        label = spec.label or "Tab",
        build = spec.build,
        onShow = spec.onShow,
        onHide = spec.onHide,
        wears = spec.wears or "inbox",
        count = 0,
    }
    registry[#registry + 1] = entry

    -- Registered after the mailbox was already opened once: attach this one now rather than
    -- waiting for the next MAIL_SHOW.
    if attached and _G.MailFrame then attachOne(_G.MailFrame, entry) end

    return handleFor(entry)
end

-- Borrowing Blizzard's scroll bar ------------------------------------------------

-- Not a copy of the mail frame's scroll bar. The mail frame's scroll bar.
--
-- Every previous attempt built one: UIPanelScrollFrameTemplate raised a bar of our own,
-- dressScrollBar painted Blizzard's thumb onto it, and anchorTo parked it in Blizzard's
-- recess. It was close and it was never right, because a bar is not one texture - it is a
-- track, two arrows, a thumb, the recess they sit in and the exact overhang of the arrows
-- past each end. Reproducing that list is a job with no last item.
--
-- So the bar is MOVED instead, and the wiring that said "this bar belongs to the mail
-- frame" is moved with it. Which wiring that is depends entirely on what kind of widget
-- this client's bar turns out to be, and the two kinds are wired nothing alike:
--
--   Slider - the old UIPanelScrollBarTemplate. Its scripts are written against
--   `self:GetParent()`: OnValueChanged is `self:GetParent():SetVerticalScroll(value)` and
--   the arrows walk up through their own parent. None of them names the frame it serves,
--   so SetParent alone re-points the lot. The name-based lookups in
--   ScrollFrameTemplate_OnMouseWheel and ScrollFrame_OnScrollRangeChanged are resolved at
--   call time, so aliasing `_G[ourName .. "ScrollBar"]` finishes the job. Two
--   reassignments, no art.
--
--   ScrollBar - Blizzard's modern widget, which /gba mailtree found on this client wearing
--   the classic atlases at 25x204. It is not a Slider, has no value and never looks at its
--   parent; it emits a scroll PERCENTAGE to registered callbacks and is told how big its
--   thumb should be. SetParent moves the art and nothing else, and aliasing the globals
--   onto it would be actively harmful - Blizzard's own wheel handler would call SetValue
--   on a widget that has no such method and take the panel down with it.
--
-- So the modern one is lent as art with a two-way sync instead: our own hidden Slider stays
-- the bar the template talks to, the borrowed widget shows the player where they are, and
-- each drives the other. The player sees Blizzard's bar either way, which is the whole
-- point; the difference is only in what is holding it up.
--
-- Nothing here asks which kind it is by name. It asks the widget.
--
-- There is one bar and it can only be in one place, so this is a loan and not a copy. The
-- claim view, the composer's editor and the composer's preview all want it; each asks for
-- it when it is shown, and uncoverAll gives it back on the way out.

-- Paired, not two lists. A bar measured against a box it does not belong to gives an inset
-- that is wrong by however far apart those two frames happen to sit, and it would do it
-- silently - so the body is whichever one came WITH the bar that answered.
--
-- The second pair is there for clients this addon has not been run on. /gba mailtree says
-- SendMailScrollFrame does not exist on this one at all.
local SOURCES = {
    { bar = "MailEditBoxScrollBar", body = "MailEditBox" },
    { bar = "SendMailScrollFrameScrollBar", body = "SendMailScrollFrame" },
}
local BAR_PARTS = { "ScrollUpButton", "ScrollDownButton", "ThumbTexture" }

-- Used only where the bar and the body cannot both be measured. /gba mailtree read
-- MailEditBox at 28,-93 268x190 and MailEditBoxScrollBar at 25x204 @303,-79 on this
-- client, which is 275 across and 14 above - the bar overhangs the writing area at both
-- ends.
local BAR_INSET = { x = 275, y = 14, bottom = -14 }

-- The callback owner handed to a modern bar's RegisterCallback, so the same object can be
-- given back to UnregisterCallback and nothing of ours is left attached to Blizzard's.
local LOAN = {}

local lent = nil

-- The first pair this client actually has, bar and box together.
local function source()
    for _, pair in ipairs(SOURCES) do
        local bar = _G[pair.bar]
        if bar then return bar, pair.bar, _G[pair.body], pair.body end
    end
    return nil
end

-- Asked of the widget, never of its name.
--
-- GetObjectType is the honest question for the old one - a Slider says Slider. The modern
-- one is a Frame like ten thousand other frames, so it is recognised by the two methods
-- that only a scroll bar has.
local function kindOf(bar)
    local objectType = bar.GetObjectType and bar:GetObjectType() or nil
    if objectType == "Slider" and bar.SetMinMaxValues then return "slider" end
    if bar.SetScrollPercentage and bar.RegisterCallback then return "scrollbar" end
    if bar.SetMinMaxValues and bar.SetValue then return "slider" end
    return nil
end

-- Kept field by field rather than as an argument list. GetPoint returns nil for relativeTo
-- when a region is anchored to its own parent, and a nil in the middle of a table is a hole
-- unpack stops at - which would have put the bar back by its first anchor and no other.
local function pointsOf(region)
    local saved = {}
    local count = region.GetNumPoints and region:GetNumPoints() or 0
    for index = 1, count do
        local point, relativeTo, relativePoint, x, y = region:GetPoint(index)
        saved[index] = {
            point = point, relativeTo = relativeTo, relativePoint = relativePoint,
            x = x or 0, y = y or 0,
        }
    end
    return saved
end

local function restorePoints(region, saved, height)
    region:ClearAllPoints()
    for _, p in ipairs(saved) do
        pcall(region.SetPoint, region, p.point, p.relativeTo or region:GetParent(),
            p.relativePoint or p.point, p.x, p.y)
    end
    -- A bar Blizzard pinned by one corner gets its height back by hand. One pinned by two
    -- takes it from the anchors, and setting it here would fight them.
    if #saved < 2 and height and region.SetHeight then region:SetHeight(height) end
end

-- One global, moved and remembered. The `held` box is there so that a name which had
-- nothing under it before is restored to nothing rather than to whatever we put there.
local function alias(store, name, value)
    if store[name] == nil then store[name] = { held = _G[name] } end
    _G[name] = value
end

-- Where the bar sits relative to the box it scrolls, measured rather than guessed.
--
-- This is what makes the loan land right in a frame that is not Blizzard's. Our body is
-- sized off MailEditBox already, so the same offset off our own top-left puts the bar in
-- the same place on our page that it has on theirs - one to one, without a number typed in
-- by anybody.
local function insetOf(bar, body)
    if body and body.GetLeft and body:GetLeft() and bar.GetLeft and bar:GetLeft() then
        return {
            x = math.floor(bar:GetLeft() - body:GetLeft() + 0.5),
            y = math.floor(bar:GetTop() - body:GetTop() + 0.5),
            bottom = math.floor(bar:GetBottom() - body:GetBottom() + 0.5),
        }
    end
    return BAR_INSET
end

-- Taking it, rather than pointing it at us -----------------------------------------

-- The difference matters, and the symptom that forced it was Christopher's observation
-- that the sticking was IDENTICAL in all three tabs. Three bodies of three different
-- lengths behaving the same way is not three frames each getting it wrong; it is one piece
-- of shared state that all three are losing an argument with.
--
-- The argument is over the bar's extent. A modern ScrollBar does not work out how much
-- there is to scroll - it is TOLD, by whoever owns it, and it believes the last thing it
-- heard. Moving the bar onto our frame does not end its old ownership: whatever registered
-- it against MailEditBox is still there, still computing an extent for a letter that is
-- empty, and still pushing it. Ours lands, theirs lands a moment later, and the bar settles
-- on "it all fits" - which is a bar that moves a few pixels and stops.
--
-- So the widget is taken rather than aimed. While it is ours, the two methods that describe
-- the CONTENT answer to us and to nobody else: anything else calling them is refused and
-- counted. The count is the evidence - a number that climbs is somebody else still holding
-- the wheel, and /gba uiprobe prints it.
--
-- Only those two. SetScrollPercentage is deliberately left open, because the bar's own drag
-- handling calls it on itself and gating that would break the thing we came for. Position
-- is cheap to be wrong about for one frame; extent is not.
local GATED = { "SetVisibleExtentPercentage", "SetPanExtentPercentage" }

-- True only while our own code is the one talking.
local speaking = false

-- Two lookups, and the difference between them is the whole bug this fixes.
--
-- `rawget` sees only what is on the widget's own table. `bar[name]` sees what actually gets
-- CALLED, which on a widget whose mixin is reached through __index is a function rawget
-- cannot see at all. The first version gated on rawget, found nothing, installed nothing,
-- and reported holding two methods it did not hold - so Blizzard's registration went on
-- describing MailEditBox to the bar unopposed.
--
-- Christopher found the shape of it before the code admitted to it: the composer would only
-- scroll once Blizzard's own letter had been typed into as well. That is exactly this.
-- MailEditBox empty means an extent of 1, "it all fits", which is a bar that will not move;
-- fill Blizzard's letter and MailEditBox gains a range of its own, the extent it pushes
-- drops below 1, and our bar starts working for reasons that have nothing to do with our
-- letter. A trick that makes a bug go away is a bug with a witness.
--
-- Restoring is the mirror of it: put back whatever was on the instance, which for a mixin
-- method is nothing, and the lookup falls through to where it was coming from all along.
local function seize(bar, store)
    for _, name in ipairs(GATED) do
        local original = bar[name]
        if type(original) == "function" then
            store[name] = { own = rawget(bar, name), original = original }
            bar[name] = function(self, ...)
                if speaking then return original(self, ...) end
                if lent then lent.refused = (lent.refused or 0) + 1 end
            end
        end
    end
end

local function release(bar, store)
    for name, saved in pairs(store) do
        bar[name] = saved.own
    end
end

-- The modern bar's half of the sync: it says where the player dragged to, as a fraction.
--
-- Guarded, because setting the scroll makes the frame tell the bar where it now is, which
-- would tell us again. The flag catches that while it happens in one go; the dead zone
-- further down catches the case it cannot, which is the same message arriving a frame or
-- two later.
local applying = false

-- Letting go of the cursor after we have scrolled ---------------------------------
--
-- The composer's letter is an EditBox, and an EditBox that scrolls carries Blizzard's
-- ScrollingEdit_OnUpdate, whose whole job is to keep the text cursor in view. It does that
-- by setting the scroll frame's offset itself, every frame, whenever it has been told the
-- cursor moved.
--
-- Which is right while you type and wrong the instant you reach for the wheel: the frame
-- scrolls, and on the very next frame the cursor-follow puts it back where the cursor is.
-- That is the reward tab scrolling and the offer tab refusing to - the claim view's body is
-- a plain frame with no cursor in it, and the composer's is not.
--
-- `handleCursorChange` is the flag that handler consults, so scrolling by hand clears it.
-- The cursor has not moved; the page has. Nothing here names the composer or the edit box:
-- if the scroll child has the flag it is a scrolling edit box, and if it has not, this does
-- nothing at all.
local function settle(scroll)
    local child = scroll.GetScrollChild and scroll:GetScrollChild() or nil
    if child and child.handleCursorChange then child.handleCursorChange = false end
end

local function scrollTo(scroll, percent)
    if applying or not scroll then return end
    local range = scroll.GetVerticalScrollRange and scroll:GetVerticalScrollRange() or 0
    range = math.max(range or 0, 0)

    local want = math.max(0, math.min(range, (percent or 0) * range))
    local at = scroll.GetVerticalScroll and scroll:GetVerticalScroll() or 0
    if math.abs((at or 0) - want) < 0.5 then return end

    applying = true
    scroll:SetVerticalScroll(want)
    applying = false
    settle(scroll)
end

-- The dead zone, which is what stops the two halves of the sync chasing each other.
--
-- The `applying` flag above is not enough on its own and the reason is worth writing down:
-- a modern ScrollBar does not scroll when it is told to, it scrolls TOWARDS where it was
-- told, a little each frame, and fires OnScroll on the way. So the callback arrives on a
-- later frame, long after applying has gone back to false, and the loop closes: the bar
-- tells the frame, the frame tells the bar, the bar moves a little more. On screen that is
-- a letter that scrolls on its own and a thumb that drifts under the cursor.
--
-- Half a pixel and a thousandth of the track are both below anything a player can see, and
-- either one breaks the loop by refusing to pass a message that says nothing new.
local PERCENT_EPSILON = 0.001

-- One step for the wheel and the arrows, as a fraction of everything there is to scroll.
--
-- A modern bar does not have a scroll step in pixels; it is told what fraction of the whole
-- one press moves. Twenty-four units is about a line and a half of the body font, which is
-- what Blizzard's own letter moves per click.
local STEP_PIXELS = 24

-- And one wheel click, which is worth more than one arrow press on every other frame in
-- the game. Two steps is about three lines of the body font.
local WHEEL_PIXELS = 48

-- Our side of it: the frame moved, so the thumb moves with it. This is also what puts the
-- thumb in the right place when the wheel is used, because the wheel drives the frame
-- through the template we kept.
--
-- The two things told to the bar here are NOT the same kind of thing, and conflating them
-- was the sticking bug: a letter would scroll an inch, stop dead, and only give another inch
-- after the tab had been left and come back to.
--
--   The EXTENT is how much there is to scroll - it sizes the thumb and it is what the bar
--   consults to decide whether it may move at all.
--   The PERCENTAGE is where in that we currently are.
--
-- Only the second one may be skipped when it has nothing new to say. The first was behind
-- the same early return, so on a body that opened at the top - percentage 0, wanted 0 - the
-- bar was never told there was anything below the fold. It moved as far as whatever stale
-- extent it still had from Blizzard's letter allowed, then clamped. Leaving the tab and
-- coming back happened to re-enter with a non-zero position, one update got through, and a
-- little more scrolling became possible. Which is precisely what it looked like.
local function pushToBar(bar, scroll)
    if applying or not bar or not scroll then return end

    local range = scroll.GetVerticalScrollRange and scroll:GetVerticalScrollRange() or 0
    range = math.max(range or 0, 0)
    local visible = scroll:GetHeight() or 0
    local total = visible + range

    applying, speaking = true, true

    -- Always. Cheap, idempotent, and the one message the bar cannot do without.
    local extent = total > 0 and math.min(1, visible / total) or 1
    if bar.SetVisibleExtentPercentage then bar:SetVisibleExtentPercentage(extent) end

    -- What one wheel click or one arrow press is worth. Left unset, a bar whose steps are
    -- measured against a body it no longer scrolls either jumps the whole page or refuses
    -- to move.
    if bar.SetPanExtentPercentage then
        bar:SetPanExtentPercentage(total > 0 and math.min(1, STEP_PIXELS / total) or 0)
    end

    -- This one may be skipped, and skipping it is what keeps the loop from closing.
    local want = range > 0
        and math.min(1, math.max(0, (scroll:GetVerticalScroll() or 0) / range)) or 0
    local at = bar.GetScrollPercentage and bar:GetScrollPercentage() or nil
    if not (at and math.abs(at - want) < PERCENT_EPSILON) then
        if bar.SetScrollPercentage then bar:SetScrollPercentage(want) end
    end

    applying, speaking = false, false
end

-- Frame levels, kept as offsets from the bar's own.
--
-- Recorded rather than assumed because a scroll bar is not one frame: the track, the thumb
-- and the two arrows sit at their own levels above it, and whether SetFrameLevel on the bar
-- carries them along is a client-by-client answer this addon should not need to know. With
-- the offsets in hand it can simply set all of them.
local function levelsOf(bar)
    local base = bar.GetFrameLevel and bar:GetFrameLevel() or 0
    local offsets = {}

    local function walk(frame)
        if not frame.GetChildren then return end
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if not ok then return end
        for _, child in ipairs(children) do
            if child.GetFrameLevel then
                offsets[#offsets + 1] = { frame = child, offset = child:GetFrameLevel() - base }
            end
            walk(child)
        end
    end

    walk(bar)
    return base, offsets
end

local function applyLevels(bar, offsets, target)
    bar:SetFrameLevel(target)
    for _, each in ipairs(offsets) do
        if each.frame.SetFrameLevel then
            each.frame:SetFrameLevel(math.max(0, target + each.offset))
        end
    end
end

-- The highest frame level anything on this window is using, so the bar can go above it.
--
-- `scroll:GetFrameLevel() + 5` was not this. It was a level above the frame the bar was
-- anchored to and nothing else, and on the composer that put it under the page furniture:
-- the bar was behind our own panels, barely visible through them, and - much worse - the
-- mouse-up that ends a thumb drag was landing on whatever was on top instead of on the
-- thumb. A drag that is never told it ended is a thumb that follows the cursor forever,
-- which is exactly what it was doing.
--
-- `skip` is the bar's own subtree, left out so that asking this question twice does not
-- ratchet the answer up by five each time.
local function topLevel(root, skip)
    local top = 0

    local function walk(frame)
        if frame == skip then return end
        if frame.GetFrameLevel then
            local level = frame:GetFrameLevel() or 0
            if level > top then top = level end
        end
        if not frame.GetChildren then return end
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if not ok then return end
        for _, child in ipairs(children) do walk(child) end
    end

    walk(root)
    return top
end

-- The window the bar is landing on: the outermost frame that is not UIParent. Everything
-- competing with the bar for the front is inside it, Blizzard's furniture included.
local function windowOf(frame)
    local top = frame
    while true do
        local parent = top.GetParent and top:GetParent() or nil
        if not parent or parent == _G.UIParent or parent == top then return top end
        top = parent
    end
end

-- Clearing a path for the wheel ---------------------------------------------------

-- A frame that takes the mouse and does NOT take the wheel eats wheel events rather than
-- letting them past, and that is how every wheel event went missing.
--
-- /gba scrollprobe caught it exactly, which is the whole reason that command exists. The
-- cursor over the composer's letter was on:
--
--   GuildLedgerOfferBody  ScrollFrame  level 3  mouse  wheel
--   (unnamed)              EditBox      level 4  mouse  no wheel
--
-- The edit box is our own scroll child, it sits a level above the frame that scrolls it,
-- it is mouse-enabled because you type in it, and it has no use for the wheel - so it
-- swallowed all of them. Five seconds of spinning the wheel over the letter produced zero
-- events at the scroll frame, and the thumb worked the whole time because a drag lands on
-- the bar, which is nowhere near any of this.
--
-- The same shape is waiting in the claim view, where the item buttons are mouse-enabled for
-- their tooltips, so this is not fixed by naming the edit box. Anything inside the body
-- that takes the mouse and not the wheel gets the wheel enabled and handed straight back to
-- the frame that scrolls.
--
-- Walked on every placement rather than once, because the claim view builds its item
-- buttons as offers need them and a button created after the loan would be a fresh hole.
-- `root` is where to start walking, and it is not always our own frame.
--
-- Blizzard's letter is still there. MailEditBox is covered at alpha 0 and its own mouse is
-- switched off, but cover() never touched its CHILDREN - and the edit box inside it is
-- mouse-enabled, wheel-less, and occupies the exact rectangle our letter occupies, one
-- frame level above it. /gba scrollprobe caught the cursor flicking between the two:
--
--   (unnamed)  EditBox  level 4  mouse  wheel      <- ours
--   (unnamed)  EditBox  level 5  mouse  no wheel   <- Blizzard's, on top, eating them
--
-- Which is the whole of the offer tab's wheel problem, and it matches what Christopher
-- described exactly: the wheel worked on the claim view, never on the composer, and the
-- counters bear it out - every wheel event in that log arrived while the cursor was over
-- GuildLedgerDetailBody and not one arrived over GuildLedgerOfferBody.
--
-- So Blizzard's box is given the wheel and told to hand it to us. That IS the unlock, and
-- it is better than going to Send Mail to fetch one by hand: nothing has to be typed into
-- Blizzard's letter, nothing is left enabled afterwards, and a wheel turned over that
-- rectangle scrolls the letter the player can actually see.
local function openWheel(scroll, store, except, root)
    local function forward(_, delta)
        local handler = scroll.GetScript and scroll:GetScript("OnMouseWheel")
        if handler then handler(scroll, delta) end
    end

    local function walk(frame)
        -- The borrowed bar is skipped whole, subtree and all. It is Blizzard's widget and
        -- it already handles the wheel perfectly well over itself; replacing its scripts
        -- gained nothing and made the probe harder to read, because the bar's own arrows
        -- came back reporting our forwarding rather than their own behaviour.
        if frame == except then return end

        if frame ~= scroll and not store[frame]
            and frame.IsMouseEnabled and frame:IsMouseEnabled()
            and frame.IsMouseWheelEnabled and not frame:IsMouseWheelEnabled() then
            -- `false` rather than nil for "there was no script here", so that restoring it
            -- can tell that apart from a frame this never touched.
            store[frame] = (frame.GetScript and frame:GetScript("OnMouseWheel")) or false
            frame:EnableMouseWheel(true)
            frame:SetScript("OnMouseWheel", forward)
        end

        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if ok then
            for _, child in ipairs(children) do walk(child) end
        end
    end

    walk(root or scroll)
end

local function closeWheel(store)
    for frame, prior in pairs(store) do
        if frame.SetScript then frame:SetScript("OnMouseWheel", prior or nil) end
        if frame.EnableMouseWheel then frame:EnableMouseWheel(false) end
        store[frame] = nil
    end
end

-- Hands the mail frame's scroll bar to `scroll` until somebody gives it back.
--
-- Safe to call on every refresh: the move happens once and the placement happens every
-- time, so a body that changed size gets the bar re-landed without the loan being redone.
--
-- opts: { x, y, bottom } override the measured inset; { hideable = true } lets the bar
-- disappear when there is nothing to scroll, which Blizzard's own letter does not do.
function MailTabs.lendScrollBar(scroll, opts)
    opts = opts or {}
    if not scroll or not scroll.SetVerticalScroll then return false, "not a scroll frame" end

    local bar, barName, body = source()
    if not bar or not bar.SetParent then
        return false, "this client has no mail scroll bar to borrow"
    end

    local kind = kindOf(bar)
    if not kind then
        return false, "the mail bar is a " ..
            tostring(bar.GetObjectType and bar:GetObjectType() or "?") ..
            " this addon does not know how to drive"
    end

    -- It is one bar. Whoever had it loses it.
    if lent and lent.scroll ~= scroll then MailTabs.returnScrollBar() end

    local inset = insetOf(bar, body)

    if not lent then
        lent = {
            bar = bar,
            barName = barName,
            kind = kind,
            scroll = scroll,
            aliased = {},
            home = {
                parent = bar:GetParent(),
                points = pointsOf(bar),
                height = bar.GetHeight and bar:GetHeight() or nil,
                strata = bar.GetFrameStrata and bar:GetFrameStrata() or nil,
                level = bar.GetFrameLevel and bar:GetFrameLevel() or nil,
                shown = bar.IsShown and bar:IsShown() or false,
                alpha = bar.GetAlpha and bar:GetAlpha() or 1,
            },
        }

        -- Taken BEFORE the move, because SetParent rewrites frame levels and the offsets
        -- wanted here are the ones Blizzard built the bar with.
        lent.home.baseLevel, lent.levels = levelsOf(bar)

        -- Both kinds move house. Only one of them has its wiring come along for the ride.
        bar:SetParent(scroll)

        if kind == "slider" then
            local scrollName = scroll.GetName and scroll:GetName() or nil
            if scrollName then
                alias(lent.aliased, scrollName .. "ScrollBar", bar)
                for _, suffix in ipairs(BAR_PARTS) do
                    local piece = _G[barName .. suffix]
                    if piece then
                        alias(lent.aliased, scrollName .. "ScrollBar" .. suffix, piece)
                    end
                end

                -- Whatever the template built under that name goes away while the real one
                -- is standing in for it. Hidden, not destroyed: the loan can end at any
                -- time and this is what the frame falls back to.
                local ours = lent.aliased[scrollName .. "ScrollBar"].held
                if ours and ours ~= bar and ours.Hide then
                    lent.ours = ours
                    lent.oursShown = ours.IsShown and ours:IsShown() or false
                    ours:Hide()
                end
            end

            lent.homeField = scroll.ScrollBar
            scroll.ScrollBar = bar
        else
            -- The modern one. Our own bar keeps its name and its job - it is what the
            -- template's wheel and range handlers go on talking to - and is simply put out
            -- of sight behind the borrowed art.
            local ours = scroll.ScrollBar
                or (scroll.GetName and _G[scroll:GetName() .. "ScrollBar"]) or nil
            if ours and ours ~= bar and ours.Hide then
                lent.ours = ours
                lent.oursShown = ours.IsShown and ours:IsShown() or false
                ours:Hide()
            end

            -- The wheel, taken as well, and for the same reason the extent was.
            --
            -- The template's own handler is written for the bar the template built: it
            -- looks up `_G[ourName .. "ScrollBar"]` and calls SetValue on whatever answers.
            -- On this path that is our hidden Slider, not the borrowed widget, and the
            -- whole chain from there to the body runs through a frame nobody can see. It
            -- did not carry - the wheel and a two-finger drag, which the client delivers as
            -- the same event, both did nothing at all.
            --
            -- So the frame scrolls itself, by pixels, and the OnVerticalScroll hook below
            -- moves the thumb to match. No hidden slider in the middle of it.
            lent.wheelScript = scroll.GetScript and scroll:GetScript("OnMouseWheel") or nil
            lent.wheelEnabled = scroll.IsMouseWheelEnabled
                and scroll:IsMouseWheelEnabled() or false

            scroll:EnableMouseWheel(true)
            scroll:SetScript("OnMouseWheel", function(self, delta)
                local range = self:GetVerticalScrollRange() or 0
                local at = self:GetVerticalScroll() or 0
                local want = math.max(0, math.min(range, at - (delta or 0) * WHEEL_PIXELS))
                self:SetVerticalScroll(want)
                settle(self)
                -- Counted here rather than anywhere else, because the useful question is
                -- not "did the wheel fire" but "did the wheel fire AND did the body move".
                MailTabs.tick("wheel", math.abs(want - at) > 0.5)
            end)

            -- Taken before it is wired, so that nothing can describe a different body to
            -- it between the two.
            lent.seized = {}
            lent.refused = 0
            seize(bar, lent.seized)

            -- Interpolation off, where the widget will admit to having any.
            --
            -- A modern bar eases towards where it was told to go, a little each frame, and
            -- reports its position the whole way. Against a scroll frame that reports back
            -- that is a conversation with no end to it - so the easing goes, and the bar
            -- simply arrives. The dead zones in the sync cover the clients where this
            -- method does not exist.
            if bar.SetInterpolateScroll then
                pcall(bar.SetInterpolateScroll, bar, false)
            end

            -- Dragged, clicked or stepped on the borrowed bar: our frame follows.
            if bar.RegisterCallback then
                local event = "OnScroll"
                if _G.ScrollBarMixin and _G.ScrollBarMixin.Event
                    and _G.ScrollBarMixin.Event.OnScroll then
                    event = _G.ScrollBarMixin.Event.OnScroll
                end
                lent.event = event
                lent.wired = pcall(bar.RegisterCallback, bar, event, function(_, percent)
                    MailTabs.tick("barScroll")
                    scrollTo(lent and lent.scroll, percent)
                end, LOAN)
            end

            -- Scrolled by anything at all - the wheel, a cursor moving in an edit box,
            -- SetVerticalScroll from our own code: the thumb follows. Hooked once per
            -- frame however many times the bar is lent to it, because HookScript stacks.
            if not scroll.grBarSync then
                scroll.grBarSync = true

                local function follow(self)
                    if lent and lent.scroll == self and lent.kind == "scrollbar" then
                        pushToBar(lent.bar, self)
                    end
                end

                scroll:HookScript("OnVerticalScroll", function(self)
                    MailTabs.tick("frameScroll")
                    follow(self)
                end)

                -- And when the body changed LENGTH rather than position, which is its own
                -- event and not the one above. Typing into the composer grows the letter
                -- without moving it, and a bar still sized for the old length is a bar that
                -- stops short of the new bottom.
                scroll:HookScript("OnScrollRangeChanged", function(self)
                    MailTabs.tick("ranged")
                    follow(self)
                end)
            end
        end

        lent.hideable = scroll.scrollBarHideable
    end

    -- Placement, every time.
    --
    -- In front of the whole window, not merely in front of the frame it scrolls. A bar
    -- behind our own panels is not just hard to see: the mouse-up that ends a thumb drag
    -- lands on whatever is in front of it, the drag is never told it ended, and the thumb
    -- follows the cursor around for the rest of the session.
    if scroll.GetFrameStrata then bar:SetFrameStrata(scroll:GetFrameStrata()) end
    applyLevels(bar, lent.levels or {}, topLevel(windowOf(scroll), bar) + 5)
    bar:SetAlpha(1)

    bar:ClearAllPoints()
    local x = opts.x or inset.x
    bar:SetPoint("TOPLEFT", scroll, "TOPLEFT", x, opts.y or inset.y)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", x, opts.bottom or inset.bottom)

    -- Every placement, because our own content is what blocks the wheel and our own
    -- content is rebuilt as offers need it.
    lent.wheelOpened = lent.wheelOpened or {}
    openWheel(scroll, lent.wheelOpened, bar)
    -- And Blizzard's letter, which sits in the same rectangle as ours and above it.
    if body then openWheel(scroll, lent.wheelOpened, bar, body) end

    -- Shown even with nothing to scroll, because that is what Send Mail does: the track is
    -- part of the page's edge, and an edge that vanishes when the letter is short reads as
    -- a bug rather than as a tidy hint.
    scroll.scrollBarHideable = opts.hideable and true or false
    if bar.SetHideIfUnscrollable then
        pcall(bar.SetHideIfUnscrollable, bar, opts.hideable and true or false)
    end

    MailTabs.refreshScrollBar(scroll)
    return true
end

-- Re-reads the range and puts the bar where the body now says it should be.
--
-- Called whenever the content changed length, which the loan cannot notice for itself.
function MailTabs.refreshScrollBar(scroll)
    scroll = scroll or (lent and lent.scroll)
    if not lent or not scroll or lent.scroll ~= scroll then return false end

    local bar = lent.bar
    if scroll.UpdateScrollChildRect then pcall(scroll.UpdateScrollChildRect, scroll) end

    local range = scroll.GetVerticalScrollRange and scroll:GetVerticalScrollRange() or 0
    range = math.max(range or 0, 0)

    -- The frame's OWN handler, asked for by script rather than by name.
    --
    -- Calling ScrollFrame_OnScrollRangeChanged directly would work on this client and is
    -- one more global name to be wrong about on the next; whatever the template wired to
    -- OnScrollRangeChanged is the right function by definition, and it is already holding
    -- the frame it belongs to. On the slider path this is also what greys the arrows out
    -- at the two ends.
    if lent.kind == "slider" then
        local ranged = scroll.GetScript and scroll:GetScript("OnScrollRangeChanged")
        if ranged then
            pcall(ranged, scroll, 0, range)
        else
            bar:SetMinMaxValues(0, range)
            local at = scroll.GetVerticalScroll and scroll:GetVerticalScroll() or 0
            bar:SetValue(math.min(at or 0, range))
        end
    else
        -- Deliberately NOT through the template's range handler on this path.
        --
        -- That handler exists to look after the bar the template built, and looking after
        -- it includes showing it: with scrollBarHideable false it calls Show on our own
        -- Slider every time it runs, which put our plain grey bar back underneath the
        -- borrowed one on every refresh. Nothing on this path needs it - the wheel is ours
        -- and the borrowed widget is told the range directly - so it is left alone and our
        -- own bar stays put away.
        if lent.ours and lent.ours.Hide then lent.ours:Hide() end
        pushToBar(bar, scroll)
    end

    bar:Show()
    return true
end

-- Gives it back, exactly as it was found.
--
-- Called from uncoverAll, so every path that hands Blizzard its mailbox back hands the bar
-- back with it - including the one nobody writes code for, which is the player clicking
-- Send Mail while our tab is up.
function MailTabs.returnScrollBar()
    if not lent then return false end

    local bar, home, scroll = lent.bar, lent.home, lent.scroll

    for name, saved in pairs(lent.aliased) do _G[name] = saved.held end

    if lent.wired and bar.UnregisterCallback and lent.event then
        pcall(bar.UnregisterCallback, bar, lent.event, LOAN)
    end
    if lent.seized then release(bar, lent.seized) end

    if lent.wheelOpened then closeWheel(lent.wheelOpened) end

    if scroll and lent.kind == "scrollbar" and lent.wheelEnabled ~= nil then
        scroll:SetScript("OnMouseWheel", lent.wheelScript)
        scroll:EnableMouseWheel(lent.wheelEnabled)
    end

    if scroll then
        if lent.homeField ~= nil then scroll.ScrollBar = lent.homeField end
        scroll.scrollBarHideable = lent.hideable
    end
    if lent.ours and lent.oursShown and lent.ours.Show then lent.ours:Show() end

    bar:SetParent(home.parent)
    if home.strata then bar:SetFrameStrata(home.strata) end
    if home.level then applyLevels(bar, lent.levels or {}, home.level) end
    bar:SetAlpha(home.alpha or 1)
    restorePoints(bar, home.points, home.height)
    if home.shown then bar:Show() else bar:Hide() end

    lent = nil
    return true
end

-- Counts what reaches the borrowed scroll bar, for /gba scrollprobe. The shipped addon counts
-- nothing: the dev build replaces this inside the region below, which holds everything the
-- /gba uiprobe and /gba scrollprobe diagnostics use and is left out of what players install.
function MailTabs.tick() end

-- The scroll bar's surround ------------------------------------------------------

-- The thumb, which UIPanelScrollFrameTemplate leaves as its own generic knob.
--
-- MailEditBoxScrollBarThumbTexture is one of the few named pieces on the real bar - 18x24,
-- fileID 130849 - so the mail frame's own knob can be put on our slider directly rather
-- than approximated.
function MailTabs.dressScrollBar(bar)
    if not bar or not bar.SetThumbTexture then return false end

    local knob = bar:GetThumbTexture()
    if not knob then return false end

    local source = _G.MailEditBoxScrollBarThumbTexture
    local file = source and source.GetTexture and source:GetTexture()
    if file then
        knob:SetTexture(file)
    else
        knob:SetTexture(130849)
    end

    knob:SetSize(18, 24)
    return true
end

function MailTabs.count()
    return #registry
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("MAIL_SHOW")
-- The mailbox closing is watched for the borrowed scroll bar and nothing else.
--
-- Every other way out of our tab goes through uncoverAll, which gives it back. Walking away
-- from the mailbox does not: the frame simply hides, our panel hides with it, and the bar
-- is left parented to a scroll frame nobody can see. It would come back the next time a tab
-- was clicked, which is one mailbox too late for anyone who opened Send Mail expecting to
-- scroll a letter.
--
-- The close comes from Mailbox.lua, not MAIL_CLOSED directly: this client never fired MAIL_CLOSED
-- in the mail probe (docs/fix-plan.md, NEW-5), so the bar was never given back.
frame:SetScript("OnEvent", function() MailTabs.attach() end)
if ns.Mailbox then ns.Mailbox.onClose(function() MailTabs.returnScrollBar() end) end
