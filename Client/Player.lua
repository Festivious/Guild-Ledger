local addonName, ns = ...
if ns and ns.standDown then return end

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA then return end

GBA.RegisterModule("Player", GBA.addonVersion(addonName))

