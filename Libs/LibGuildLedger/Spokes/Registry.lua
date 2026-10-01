-- Holds the spoke adapters and answers "what is available, at what version".
--
-- The answer feeds the provenance envelope, so the corpus records each observation's
-- enrichment level instead of silently mixing thin and rich rows.
local ns = LibStub and LibStub("LibGuildLedger-1.0", true)
if ns and not ns.loading then return end

local Adapter = ns and ns.Adapter or require("Spokes.Adapter")

local Registry = {}
Registry.__index = Registry

function Registry.new()
    return setmetatable({ adapters = {}, order = {}, state = {} }, Registry)
end

function Registry:register(adapter)
    if type(adapter) ~= "table" or type(adapter.name) ~= "string" then
        return false, "adapter needs a name"
    end
    if self.adapters[adapter.name] then
        return false, "already registered: " .. adapter.name
    end
    self.adapters[adapter.name] = adapter
    self.order[#self.order + 1] = adapter.name
    return true
end

function Registry:get(name)
    return self.adapters[name]
end

-- Detection never throws: an adapter whose detect errors is simply reported absent.
function Registry:detectAll(env)
    self.state = {}
    self.env = env
    for _, name in ipairs(self.order) do
        local adapter = self.adapters[name]
        local ok, present, version = Adapter.safeCall(adapter.detect, env)
        if not ok then present, version = false, nil end

        if present and not Adapter.meetsMinimum(version, adapter.minVersion) then
            self.state[name] = {
                present = false,
                version = version,
                reason = "version " .. tostring(version) ..
                    " below required " .. tostring(adapter.minVersion),
            }
        else
            self.state[name] = { present = present and true or false, version = version }
        end
    end
    return self.state
end

function Registry:isAvailable(name)
    local entry = self.state[name]
    return entry ~= nil and entry.present
end

-- name -> version string, for the provenance envelope. Absent spokes are omitted, so the
-- envelope records what actually contributed rather than a list of nils.
function Registry:versions()
    local out = {}
    for name, entry in pairs(self.state) do
        if entry.present then
            out[name] = tostring(entry.version or "unknown")
        end
    end
    return out
end

-- Ordered rows for display: { name, present, version, reason }
function Registry:report()
    local rows = {}
    for _, name in ipairs(self.order) do
        local entry = self.state[name] or { present = false }
        rows[#rows + 1] = {
            name = name,
            present = entry.present,
            version = entry.version,
            reason = entry.reason,
        }
    end
    return rows
end

-- Calls a capability on a spoke, returning nil when the spoke is absent or misbehaves.
-- Capabilities receive the detected environment as their first argument.
function Registry:call(name, capability, ...)
    if not self:isAvailable(name) then return nil, "spoke unavailable: " .. name end
    local adapter = self.adapters[name]
    local fn = adapter and adapter[capability]
    if type(fn) ~= "function" then
        return nil, "no capability '" .. tostring(capability) .. "' on " .. name
    end
    local ok, result = Adapter.safeCall(fn, self.env, ...)
    if not ok then return nil, tostring(result) end
    return result
end

if ns then ns.Registry = Registry end
return Registry
