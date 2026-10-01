-- One install, never two.
--
-- GuildLedger_Guild carries this whole addon inside it (tools/sync-lib.lua copies it into
-- GuildLedger_Guild/Client), so an officer runs the Guild addon alone. With both enabled,
-- every file here would run twice: two capture buffers writing one saved variable, two
-- Rewards tabs, two claim flows answering the same mail. So when the Guild addon is enabled
-- on this character, this copy stands down, and every file after this one returns at once.
--
-- Checked only when this file runs as GuildLedger. The copy inside the Guild addon is the
-- one that must run, and there addonName is GuildLedger_Guild.
local addonName, ns = ...

local GUILD = "GuildLedger_Guild"

local function guildEnabled()
    local api = C_AddOns
    if not api then return false end
    if api.IsAddOnLoaded and api.IsAddOnLoaded(GUILD) then return true end
    if api.GetAddOnEnableState then
        local ok, state = pcall(api.GetAddOnEnableState, GUILD, UnitName("player"))
        if ok and type(state) == "number" then return state > 0 end
    end
    return false
end

if addonName ~= "GuildLedger" or not guildEnabled() then return end

ns.standDown = true

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Guild Ledger:|r the Officers version already includes it, "
        .. "so this copy is switched off. In the AddOns list keep only Guild Ledger (Officers).")
end)
