-- The hard quest list: guild quests shipped with the addon. Data only, no WoW API use.
--
-- Spec: docs/superpowers/specs/2026-09-25-hard-quest-list-design.md, Part 5.
--
-- Nothing here is on until an officer ticks it (the guild pays). Quest ids are permanent: never
-- renumber one, never reuse one, even after a quest is removed. Zones are uiMapIDs; mobs, items
-- and pay are ids and copper. Blocks of 100 per zone; within a block, x01-x02 are mail-ins, x03
-- the kill quest, x04-x06 herbs, ore and skins, x07 onward Cooking and First Aid. Guild
-- suggestions take x50 upward.
--
-- The voice of every title and note: an invitation, never an order. A quest is a bonus for how
-- somebody already plays, and a note explains what the guides know without holding a hand.
--
-- Pay is a placeholder: 1.5 times the area's average quest coin (2s 60c at 5-8, 4s 50c at 9-12,
-- 6s at 10-14, 11s 25c at 15-20), and a 10-slot bag for the big cooking projects.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local ELWYNN, DUN_MOROGH, TELDRASSIL = 1429, 1426, 1438
local WESTFALL, LOCH_MODAN, DARKSHORE = 1436, 1432, 1439

local START, MID = { 5, 12 }, { 10, 20 }

local HardList = {
    -- Elwynn Forest ------------------------------------------------------------------------
    { id = 101, zone = ELWYNN, levels = START, pay = { copper = 260 },
      title = "Lucky Feet",
      steps = { { kind = "mail", items = { 3300 }, count = 9 } },   -- Rabbit's Foot
      note = "Elwynn's wolves carry more rabbit's feet than the rabbits do. If you're thinning them " ..
             "out anyway, keep nine of the feet and mail them to an officer." },
    { id = 102, zone = ELWYNN, levels = START, pay = { copper = 260 },
      title = "Tusks for the Trophy Wall",
      steps = { { kind = "mail", items = { 3171 }, count = 10 } },  -- Broken Boar Tusk
      note = "Every boar you drop for meat leaves a Broken Boar Tusk now and then. Don't vendor them: " ..
             "ten tusks, mailed in, and the guild wall gets a little fiercer." },
    { id = 103, zone = ELWYNN, levels = START, pay = { copper = 450 },
      title = "The Frontier, Properly",
      steps = { { kind = "kill", groups = {
          { npcs = { 118 }, count = 24 },     -- Prowler
          { npcs = { 822 }, count = 15 },     -- Young Forest Bear
      } } },
      note = "Guard Thomas at the east bridge asks for 8 Prowlers and 5 bears. We think the frontier " ..
             "deserves three times that. Stay out past dark if you like." },
    { id = 104, zone = ELWYNN, levels = START, pay = { copper = 260 },
      title = "Green Thumb",
      steps = { { kind = "gather", skill = "herb", count = 50 } },
      note = "Peacebloom, Silverleaf and Earthroot grow all over Elwynn, and they'll carry Herbalism to " ..
             "70. Pick fifty. Train Journeyman at 50 so you're not stuck." },
    { id = 105, zone = ELWYNN, levels = START, pay = { copper = 260 },
      title = "Copper Country",
      steps = { { kind = "gather", skill = "mine", count = 50 } },
      note = "Copper veins line the hills and the mines. Fifty veins takes Mining most of the way to " ..
             "65. Keep a Mining Pick in your bags, and train Journeyman at 50." },
    { id = 106, zone = ELWYNN, levels = START, pay = { copper = 260 },
      title = "Hides of Elwynn",
      steps = { { kind = "gather", skill = "skin", count = 50 } },
      note = "Wolves, boars and bears: if it has fur, it has leather. Skin fifty. Up to skill 100, " ..
             "the highest level you can skin is your skill divided by 10, plus 10." },
    { id = 107, zone = ELWYNN, levels = START, pay = { copper = 260 },
      title = "Something with a Kick",
      steps = { { kind = "craft", items = { { 2680, 20 } } } },     -- Spiced Wolf Meat
      note = "Spiced Wolf Meat needs Cooking 10 and costs 50 copper to learn. Most people walk past " ..
             "it. Unlike Charred Wolf Meat, it feeds you a buff: +2 Stamina and Spirit. Cook twenty." },
    { id = 108, zone = ELWYNN, levels = START, pay = { copper = 260 },
      title = "Linen for the Wounded",
      steps = { { kind = "craft", items = { { 1251, 50 } } } },     -- Linen Bandage
      note = "Fifty Linen Bandages takes First Aid from 1 to about 40, the guides' own route. The " ..
             "Defias and kobolds here drop Linen at roughly half their kills." },
    { id = 109, zone = ELWYNN, levels = START, pay = { bagSlots = 10 },
      title = "The Butcher's Apprentice",
      steps = { { kind = "craft", items = { { 2681, 90 } } } },     -- Roasted Boar Meat
      note = "Before Fargodeep Mine, spend some time on the boars: 90 Roasted Boar Meat. You'll walk " ..
             "into the mine around level 9 or 10, fed, with Cooking started. Your call when." },

    -- Dun Morogh ---------------------------------------------------------------------------
    { id = 201, zone = DUN_MOROGH, levels = START, pay = { copper = 260 },
      title = "Fangs in the Snow",
      steps = { { kind = "mail", items = { 4814 }, count = 22 } },  -- Discolored Fang
      note = "The snow leopards leave Discolored Fangs behind about every other kill. Twenty-two of " ..
             "them, mailed in, if the leopards give you trouble anyway." },
    { id = 202, zone = DUN_MOROGH, levels = START, pay = { copper = 450 },
      title = "Trogg Laundry",
      steps = { { kind = "mail", items = { 2591 }, count = 15 } },  -- Dirty Trogg Cloth
      note = "Nobody knows why the Rockjaw troggs carry Dirty Trogg Cloth. Nobody wants to know. " ..
             "Fifteen pieces, mailed in, and we'll ask no questions either." },
    { id = 203, zone = DUN_MOROGH, levels = START, pay = { copper = 450 },
      title = "Those Blasted Troggs, Again",
      steps = { { kind = "kill", groups = {
          { npcs = { 1115 }, count = 18 },    -- Rockjaw Skullthumper
          { npcs = { 1117 }, count = 30 },    -- Rockjaw Bonesnapper
      } } },
      note = "The quarry asks for 6 Skullthumpers and 10 Bonesnappers. The troggs keep coming back, " ..
             "so we're asking for three times that." },
    { id = 204, zone = DUN_MOROGH, levels = START, pay = { copper = 260 },
      title = "Flowers Under the Frost",
      steps = { { kind = "gather", skill = "herb", count = 50 } },
      note = "Peacebloom, Silverleaf and Earthroot survive the snow, and they'll carry Herbalism to 70. " ..
             "Pick fifty. Train Journeyman at 50." },
    { id = 205, zone = DUN_MOROGH, levels = START, pay = { copper = 260 },
      title = "Dwarven Copper",
      steps = { { kind = "gather", skill = "mine", count = 50 } },
      note = "Fifty Copper veins, most of the way to Mining 65. Keep a Mining Pick with you, and " ..
             "train Journeyman at 50." },
    { id = 206, zone = DUN_MOROGH, levels = START, pay = { copper = 260 },
      title = "Around the Lake",
      steps = { { kind = "gather", skill = "skin", count = 50 } },
      note = "The skinning guides start here: circle the lake near Ironforge and skin everything on " ..
             "the way. Fifty skins takes you to about 50. Train Journeyman in Ironforge." },
    { id = 207, zone = DUN_MOROGH, levels = START, pay = { copper = 260 },
      title = "Something with a Kick",
      steps = { { kind = "craft", items = { { 2680, 20 } } } },     -- Spiced Wolf Meat
      note = "Spiced Wolf Meat needs Cooking 10 and costs 50 copper to learn. It feeds you a buff, " ..
             "+2 Stamina and Spirit, which the plain version doesn't. Cook twenty." },
    { id = 208, zone = DUN_MOROGH, levels = START, pay = { copper = 260 },
      title = "Linen for the Wounded",
      steps = { { kind = "craft", items = { { 1251, 50 } } } },     -- Linen Bandage
      note = "Fifty Linen Bandages takes First Aid from 1 to about 40. The Frostmane trolls and the " ..
             "troggs drop Linen at around half their kills." },
    { id = 209, zone = DUN_MOROGH, levels = START, pay = { bagSlots = 10 },
      title = "The Thunderbrew Supper",
      steps = { { kind = "craft", items = { { 2681, 45 }, { 2888, 45 } } } },  -- Roasted Boar Meat, Beer Basted Boar Ribs
      note = "The Crag Boars drop meat and ribs off the same kills. Cook 45 Roasted Boar Meat and 45 " ..
             "Beer Basted Boar Ribs (that one needs Cooking 25)." },

    -- Teldrassil ---------------------------------------------------------------------------
    { id = 301, zone = TELDRASSIL, levels = START, pay = { copper = 260 },
      title = "Nightsaber Teeth",
      steps = { { kind = "mail", items = { 4814 }, count = 20 } },  -- Discolored Fang
      note = "The nightsabers drop Discolored Fangs at better than one kill in three. Twenty of them, " ..
             "mailed in." },
    { id = 302, zone = TELDRASSIL, levels = START, pay = { copper = 260 },
      title = "Leg Day",
      steps = { { kind = "mail", items = { 1476 }, count = 25 } },  -- Snapped Spider Limb
      note = "The Webwood spiders snap a limb about half the time you kill one. Twenty-five Snapped " ..
             "Spider Limbs. Please wrap them." },
    { id = 303, zone = TELDRASSIL, levels = START, pay = { copper = 450 },
      title = "Feathers Will Fly",
      steps = { { kind = "kill", npcs = { 2015, 2017, 2018, 2019, 2020, 2021 }, count = 45 } },
      note = "The Bloodfeather harpies have the Oracle Glade. Any kind of harpy counts: forty-five of " ..
             "them. The real quest wants their belts, so you'll likely do both." },
    { id = 304, zone = TELDRASSIL, levels = START, pay = { copper = 260 },
      title = "Moonlit Herbs",
      steps = { { kind = "gather", skill = "herb", count = 50 } },
      note = "Peacebloom, Silverleaf and Earthroot grow thick under the tree. Pick fifty. There's no ore " ..
             "anywhere on Teldrassil; if you mine, your first vein is waiting in Darkshore." },
    { id = 306, zone = TELDRASSIL, levels = START, pay = { copper = 260 },
      title = "Hides of the Tree",
      steps = { { kind = "gather", skill = "skin", count = 50 } },
      note = "The nightsabers are everywhere. Skin fifty. Up to skill 100, the highest level you can " ..
             "skin is your skill divided by 10, plus 10." },
    { id = 308, zone = TELDRASSIL, levels = START, pay = { copper = 260 },
      title = "Linen for the Wounded",
      steps = { { kind = "craft", items = { { 1251, 50 } } } },     -- Linen Bandage
      note = "Fifty Linen Bandages takes First Aid from 1 to about 40. The Gnarlpine furbolgs drop " ..
             "Linen more often than not." },
    { id = 309, zone = TELDRASSIL, levels = START, pay = { bagSlots = 10 },
      title = "Breakfast for Dolanaar",
      steps = { { kind = "craft", items = { { 6888, 90 } } } },     -- Herb Baked Egg
      note = "No boar meat grows on this tree, but the Strigid owls drop Small Eggs more often than " ..
             "not. Ninety Herb Baked Eggs. It's a lot of owls. We believe in you." },

    -- Westfall -----------------------------------------------------------------------------
    { id = 401, zone = WESTFALL, levels = MID, pay = { copper = 600 },
      title = "Plucked",
      steps = { { kind = "mail", items = { 555 }, count = 17 } },   -- Rough Vulture Feathers
      note = "The Fleshrippers drop Rough Vulture Feathers about a third of the time. Seventeen, " ..
             "mailed in." },
    { id = 402, zone = WESTFALL, levels = MID, pay = { copper = 600 },
      title = "Coyote Ugly",
      steps = { { kind = "mail", items = { 3299 }, count = 15 } },  -- Fractured Canine
      note = "The coyotes break their teeth on everything. Fifteen Fractured Canines, mailed in." },
    { id = 403, zone = WESTFALL, levels = MID, pay = { copper = 1125 },
      title = "The Killing Fields, Properly",
      steps = { { kind = "kill", npcs = { 114 }, count = 200 } },   -- Harvest Watcher
      note = "Farmer Saldean asks for 20 Harvest Watchers. We're asking for 200. They respawn fast, " ..
             "they hit hard, and it's a great fight. Yes, two hundred." },
    { id = 404, zone = WESTFALL, levels = MID, pay = { copper = 600 },
      title = "Westfall Wildflowers",
      steps = { { kind = "gather", skill = "herb", count = 60 } },
      note = "Briarthorn, Mageroyal and a lot of Stranglekelp along the coast (that one needs " ..
             "Herbalism 85). Sixty herbs. Journeyman first, if you haven't." },
    { id = 405, zone = WESTFALL, levels = MID, pay = { copper = 600 },
      title = "Tin and Copper",
      steps = { { kind = "gather", skill = "mine", count = 60 } },
      note = "Copper and Tin both show up here. Sixty veins. Tin takes Mining past 65." },
    { id = 406, zone = WESTFALL, levels = MID, pay = { copper = 600 },
      title = "Hides of Westfall",
      steps = { { kind = "gather", skill = "skin", count = 60 } },
      note = "Coyotes and Goretusks, all over the farms. Skin sixty." },
    { id = 407, zone = WESTFALL, levels = MID, pay = { copper = 600 },
      title = "The Crab Chain",
      steps = {
          { kind = "craft", items = { { 2683, 10 } } },             -- Crab Cake
          { kind = "craft", items = { { 2682, 20 } } },             -- Cooked Crab Claw
      },
      note = "The guides' Cooking route through 75-100: ten Crab Cakes, then twenty Cooked Crab Claws. " ..
             "Keep every Crawler Claw you find. The claw recipe is sold by Kendor Kabonka in Stormwind." },
    { id = 408, zone = WESTFALL, levels = MID, pay = { copper = 600 },
      title = "Wool for the Wounded",
      steps = { { kind = "craft", items = { { 3530, 60 } } } },     -- Wool Bandage
      note = "Sixty Wool Bandages takes First Aid from 80 toward 115. The Defias and gnolls here drop " ..
             "Wool about a third of the time. Train Journeyman at 75 first." },

    -- Loch Modan ---------------------------------------------------------------------------
    { id = 501, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "Bear Necessities",
      steps = { { kind = "mail", items = { 3169 }, count = 14 } },  -- Chipped Bear Tooth
      note = "The black bears chip their teeth on everything. Fourteen Chipped Bear Teeth, mailed in." },
    { id = 502, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "Hairy Business",
      steps = { { kind = "mail", items = { 3167 }, count = 12 } },  -- Thick Spider Hair
      note = "The lurkers in the hills carry Thick Spider Hair. Twelve, mailed in." },
    { id = 503, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "In Defense of the King's Lands, Again",
      steps = { { kind = "kill", npcs = { 1161, 1162, 1163, 1164, 1165, 1166, 1167, 1197 }, count = 60 } },
      note = "Sixty Stonesplinter troggs of any kind, on top of the guard towers' quests. Leave the " ..
             "ogres alone at this level; they're the dangerous ones." },
    { id = 504, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "Loch Modan Blooms",
      steps = { { kind = "gather", skill = "herb", count = 60 } },
      note = "Mageroyal and Briarthorn carry Herbalism from 70 toward 115. Sixty herbs." },
    { id = 505, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "Hills of Tin",
      steps = { { kind = "gather", skill = "mine", count = 60 } },
      note = "Copper and a lot of Tin in these hills. Sixty veins." },
    { id = 506, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "Down the River",
      steps = { { kind = "gather", skill = "skin", count = 60 } },
      note = "The skinning guides send you along the river here, from 75 to 125: skin every beast " ..
             "along the way. Sixty skins." },
    { id = 507, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "Smoked and Ready",
      steps = { { kind = "craft", items = { { 6890, 40 } } } },     -- Smoked Bear Meat
      note = "The guides' Cooking route for 40-75: forty Smoked Bear Meat. Drac Roughcut in Thelsamar " ..
             "sells the recipe, and the bears are right here." },
    { id = 508, zone = LOCH_MODAN, levels = MID, pay = { copper = 600 },
      title = "Heavy Linen",
      steps = { { kind = "craft", items = { { 2581, 45 } } } },     -- Heavy Linen Bandage
      note = "Forty-five Heavy Linen Bandages takes First Aid from 40 to 75. The Stonesplinter troggs " ..
             "drop Linen more often than not, so the trogg quest pays twice." },

    -- Darkshore ----------------------------------------------------------------------------
    { id = 601, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "Thistle Teeth",
      steps = { { kind = "mail", items = { 3170 }, count = 13 } },  -- Large Bear Tooth
      note = "The Thistle Bears drop Large Bear Teeth about a quarter of the time. Thirteen, mailed in." },
    { id = 602, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "Talon Collection",
      steps = { { kind = "mail", items = { 5114 }, count = 12 } },  -- Severed Talon
      note = "The Foreststriders leave Severed Talons behind. Twelve, mailed in." },
    { id = 603, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "Bears and Birds",
      steps = { { kind = "kill", groups = {
          { npcs = { 2163, 2164, 2165 }, count = 60 },   -- Thistle Bear, Rabid, Grizzled
          { npcs = { 2321, 2322, 2323 }, count = 60 },   -- Foreststrider Fledgling, Foreststrider, Giant
      } } },
      note = "Darkshore asks for 20 Rabid Thistle Bears. We'd like 60 bears of any kind, and 60 " ..
             "Foreststriders of any size. The teeth and talons for the mail-ins come off the same kills." },
    { id = 604, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "Along the Shore",
      steps = { { kind = "gather", skill = "herb", count = 60 } },
      note = "Mageroyal and Briarthorn inland, and Stranglekelp along the shore once you reach " ..
             "Herbalism 85. Sixty herbs." },
    { id = 605, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "First Ore",
      steps = { { kind = "gather", skill = "mine", count = 60 } },
      note = "For a night elf, this is the first ore there is. Sixty veins of Copper and Tin." },
    { id = 606, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "Hides of Darkshore",
      steps = { { kind = "gather", skill = "skin", count = 60 } },
      note = "Thistle Bears and moonstalkers. Skin sixty." },
    { id = 607, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "The Crab Chain",
      steps = {
          { kind = "craft", items = { { 2683, 10 } } },             -- Crab Cake
          { kind = "craft", items = { { 2682, 20 } } },             -- Cooked Crab Claw
      },
      note = "The guides' Cooking route through 75-100: ten Crab Cakes, then twenty Cooked Crab Claws, " ..
             "from the crawlers along the shore. Keep every claw. Kendor Kabonka in Stormwind sells the recipe." },
    { id = 608, zone = DARKSHORE, levels = MID, pay = { copper = 600 },
      title = "Heavy Linen",
      steps = { { kind = "craft", items = { { 2581, 45 } } } },     -- Heavy Linen Bandage
      note = "Forty-five Heavy Linen Bandages takes First Aid from 40 to 75. The Blackwood furbolgs " ..
             "drop Linen often." },
}

-- The mailbox each zone's quests are accepted and turned in at, as the map shows it (0-100), for
-- the turn-in pins. Any mailbox in the zone works; this is the one the pin points to. From Wowhead's
-- Classic mailbox object (32349).
HardList.mailboxes = {
    [ELWYNN]     = { 42.9, 65.4, "Goldshire" },
    [DUN_MOROGH] = { 47.0, 52.4, "Kharanos" },
    [TELDRASSIL] = { 56.1, 58.4, "Dolanaar" },
    [WESTFALL]   = { 53.0, 53.5, "Sentinel Hill" },
    [LOCH_MODAN] = { 34.8, 47.7, "Thelsamar" },
    [DARKSHORE]  = { 37.3, 43.8, "Auberdine" },
}

if ns then ns.HardList = HardList end
return HardList
