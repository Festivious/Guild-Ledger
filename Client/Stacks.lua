-- Turning "twenty linen" into the attachments that actually carry twenty linen. Pure, no
-- WoW API use.
--
-- A quantity is written in one number and held in several. Twenty linen can be one stack
-- of twenty, two of ten, or a twenty sitting inside a stack of forty that must be split so
-- the other twenty stays home. The mailbox does not take a number either: it takes up to
-- twelve attachments, each of which is one bag slot's worth.
--
-- So between "the offer asks for twenty" and "pick up this bag slot" there is arithmetic,
-- and that arithmetic is here rather than beside the mailbox calls, because it is the part
-- that can be wrong in ways nobody notices. The bug this file was written for: asking for
-- twenty while holding five attached the five and called it done. The claim posted, short,
-- and said it had succeeded.
--
-- The rule that follows from it: a short entry sends NOTHING. Half a hand-in is not a
-- smaller hand-in, it is a claim the officer has to unpick by hand, and the player is
-- better told they are fifteen linen short while the items are still in their bags.
local _, ns = ...
if ns and ns.standDown then return end

local Stacks = {}

-- What the planner could not do, in the shape the caller reports it in. A reason is a code
-- rather than a sentence: the wording belongs to whoever is doing the telling.
Stacks.reason = {
    short    = "short",      -- fewer in the bags than the entry asks for
    noSlots  = "no_slots",   -- would need more attachments than are left
}

-- How many of an item the bags hold, across every stack.
function Stacks.total(inventory, itemID)
    local count = 0
    for _, stack in ipairs(inventory or {}) do
        if stack.itemID == itemID then count = count + (stack.count or 0) end
    end
    return count
end

-- The stacks of one item, as a pool that plan() draws down. Copied rather than referenced:
-- planning must not edit the caller's snapshot, and one entry's draw has to be visible to
-- the next entry asking for the same item.
local function pool(inventory)
    local out = {}
    for index, stack in ipairs(inventory or {}) do
        if stack.itemID and (stack.count or 0) > 0 then
            out[#out + 1] = {
                order = index,
                bag = stack.bag, slot = stack.slot,
                itemID = stack.itemID, left = stack.count,
            }
        end
    end
    return out
end

-- Which stacks to draw one entry's quantity from, cheapest first.
--
-- Cheapest means fewest attachments, then least disturbance to the bags. A single stack
-- that covers the whole amount is one attachment, so it wins outright; the SMALLEST such
-- stack wins among those, which is what leaves the big stack whole and takes the exact one
-- when the bags happen to hold it. Failing that, biggest stacks first, because each one
-- taken is an attachment slot spent.
local function draw(available, itemID, wanted)
    local mine = {}
    for _, stack in ipairs(available) do
        if stack.itemID == itemID and stack.left > 0 then mine[#mine + 1] = stack end
    end

    local covers
    for _, stack in ipairs(mine) do
        if stack.left >= wanted then
            if not covers or stack.left < covers.left
                or (stack.left == covers.left and stack.order < covers.order) then
                covers = stack
            end
        end
    end
    if covers then return { { stack = covers, count = wanted } } end

    table.sort(mine, function(a, b)
        if a.left ~= b.left then return a.left > b.left end
        return a.order < b.order
    end)

    local picks, need = {}, wanted
    for _, stack in ipairs(mine) do
        if need <= 0 then break end
        local take = math.min(stack.left, need)
        picks[#picks + 1] = { stack = stack, count = take }
        need = need - take
    end
    if need > 0 then return nil, wanted - need end
    return picks
end

-- What to pick up, in order, to attach the entries asked for.
--
--   entries    { { itemID = , quantity = }, ... }  the offer's side of the deal
--   inventory  { { bag = , slot = , itemID = , count = }, ... }  a snapshot of the bags
--   limit      attachments available (Classic's mailbox takes twelve)
--
-- Returns the plan - { { bag = , slot = , itemID = , count = , entry = }, ... } - and a
-- list of the entries it could not cover, each { itemID, want, have, reason }.
--
-- An entry that cannot be covered in full takes nothing: its stacks go back to the pool for
-- the entries after it, which is why a missing entry never eats an attachment slot that a
-- later one could have used.
function Stacks.plan(entries, inventory, limit)
    limit = limit or math.huge
    local available = pool(inventory)
    local plan, missing = {}, {}

    for index, entry in ipairs(entries or {}) do
        local wanted = entry.quantity or 1
        if entry.itemID and wanted > 0 then
            local picks, found = draw(available, entry.itemID, wanted)

            if not picks then
                missing[#missing + 1] = {
                    itemID = entry.itemID, want = wanted, have = found or 0,
                    reason = Stacks.reason.short,
                }
            elseif #plan + #picks > limit then
                missing[#missing + 1] = {
                    itemID = entry.itemID, want = wanted, have = wanted,
                    needs = #picks, reason = Stacks.reason.noSlots,
                }
            else
                for _, pick in ipairs(picks) do
                    pick.stack.left = pick.stack.left - pick.count
                    plan[#plan + 1] = {
                        bag = pick.stack.bag, slot = pick.stack.slot,
                        itemID = entry.itemID, count = pick.count, entry = index,
                    }
                end
            end
        end
    end

    return plan, missing
end

-- How much of each item a plan carries. The caller compares this against what it meant to
-- send, so a pick that fails at the mailbox is caught by arithmetic rather than by trust.
function Stacks.carried(plan)
    local out = {}
    for _, pick in ipairs(plan or {}) do
        out[pick.itemID] = (out[pick.itemID] or 0) + (pick.count or 0)
    end
    return out
end

if ns then ns.Stacks = Stacks end
return Stacks
