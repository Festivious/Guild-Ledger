-- The vault's status: this officer's key, the role list in force, and the sessions carried.
-- Read by the analytics frame's Vault panel (Analytics.lua).
--
-- A session held is not a session readable. Each line says which it is, and the buttons do
-- the two things an officer can do about a locked one: open the key letters in this mailbox,
-- and ask the other officers for sessions this officer has a key for but not the data.
local addonName, ns = ...

local GBA = LibStub and LibStub("LibGuildLedger-1.0", true)
if not GBA or not GBA.ListPanel then return end

local LP = GBA.ListPanel

local function lines()
    local vault = ns.Vault
    if not vault then return { "the vault is not loaded" } end
    local out = {}

    local id = vault.identity and vault.identity()
    out[#out + 1] = "Your officer key: " .. (id and (id.public:sub(1, 16) .. "...") or (LP.WAIT .. "not made yet" .. LP.END))
    local list = GBA.roles and GBA.roles.list
    out[#out + 1] = "Roles: " .. (list and ("the guild master's list " .. list.n) or "by rank (no list yet)")
    out[#out + 1] = ""

    local held, waiting = vault.overview()
    if #held == 0 and #waiting == 0 then
        out[#out + 1] = LP.DIM .. "No sessions carried yet." .. LP.END
    end
    for _, h in ipairs(held) do
        local status
        if h.unlockedAt then
            status = LP.GOOD .. "unlocked, and read" .. LP.END
        else
            status = LP.WAIT .. "locked: needs your key letter, if one was sent to you" .. LP.END
        end
        out[#out + 1] = string.format("Session %s from %s: %s", h.sid, tostring(h.from), status)
        if not h.fromDisk then out[#out + 1] = "   " .. LP.DIM .. "not saved yet; the sender keeps a copy until you reload" .. LP.END end
    end
    for _, sid in ipairs(waiting) do
        out[#out + 1] = string.format("Session %s: %skey opened; asking officers for the session%s", sid, LP.WAIT, LP.END)
    end
    return out
end

ns.vaultLines = lines

-- What an officer can do about a locked session. Shown in the analytics frame's Vault panel;
-- no longer a mail tab, because the vault is back-end work and the mailbox is for offers
-- and claims.
ns.vaultActions = {
    { label = "Open key letters", onClick = function() ns.Vault.unlockFromMail() end },
    { label = "Fetch missing", onClick = function()
        local asked = ns.Vault.fetchMissing()
        GBA.Print(asked > 0 and ("asked the officers for " .. asked .. " session(s)") or "nothing missing, or no officer online")
    end },
}
