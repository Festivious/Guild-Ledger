-- Runs last. The winning copy has finished loading, so any later copy's files step aside.
local lib = LibStub and LibStub("LibGuildLedger-1.0", true)
if lib then lib.loading = nil end
