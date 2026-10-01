-- An error log, so "check the logs" has something to check.
--
-- Classic Era hides Lua errors unless scriptErrors is on, so a file that fails to load fails
-- silently: on 2026-09-23 the guild addon stopped partway through loading and the only trace
-- was a saved variable left nil. This records every error that mentions GuildLedger, with
-- its stack, and each addon saves the log with its own saved variables.
--
-- It chains to whatever handler was there before, so the game's own error display (and any
-- error addon) still sees every error. It loads right after Lib.lua, before any GuildLedger
-- module, and the client addon loads before the guild addon, so a guild-side load error is
-- caught as well.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if not ns or not ns.loading then return end

ns.errors = ns.errors or {}
ns.MAX_ERRORS = 50

function ns.recordError(msg, stack)
    local text = tostring(msg)
    stack = stack or (debugstack and debugstack(3) or "")
    if not (text:find("GuildLedger", 1, true) or stack:find("GuildLedger", 1, true)) then return end
    for _, e in ipairs(ns.errors) do
        if e.message == text then e.count = (e.count or 1) + 1; e.last = time and time(); return end
    end
    table.insert(ns.errors, { message = text, stack = stack:sub(1, 1500), first = time and time(), count = 1 })
    while #ns.errors > ns.MAX_ERRORS do table.remove(ns.errors, 1) end
end

if geterrorhandler and seterrorhandler and not ns.errorHooked then
    ns.errorHooked = true
    local previous = geterrorhandler()
    seterrorhandler(function(msg, ...)
        pcall(ns.recordError, msg, debugstack and debugstack(2) or "")
        if previous then return previous(msg, ...) end
    end)
end
