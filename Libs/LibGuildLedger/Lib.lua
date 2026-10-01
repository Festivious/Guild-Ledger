-- LibGuildLedger: the contract GuildLedger and GuildLedger_Guild both speak.
--
-- The wire format, the transport, the reward and role models, and the UI helpers both sides
-- use. Nothing role-specific belongs here: no capture, no corpus, no officer screens. If only
-- one side calls something, it lives in that side's addon.
--
-- It is not an addon of its own. Each of the two addons carries an identical copy in
-- Libs\LibGuildLedger, made from the single source by tools/sync-lib.lua, and a test fails if
-- a copy drifts. An officer who plays installs both addons, so the library can arrive twice:
-- LibStub keeps the newest, and every other copy's files step aside.
--
-- This file runs first. While the winning copy's files load, `loading` is set; every other
-- file checks it, so a copy that lost the version race loads nothing. LibEnd.lua clears it.
local MAJOR, MINOR = "LibGuildLedger-1.0", 1

local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.MAJOR, lib.MINOR = MAJOR, MINOR
lib.loading = true
