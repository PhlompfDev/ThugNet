-- Sensor quick-setup discovery: enumerate every peripheral the computer can
-- reach (adjacent sides AND wired-modem network names both come back from
-- peripheral.getNames()) and duck-type each one into the sensor kinds it can
-- back. Pure discovery — the UI decides presentation, server_config owns the
-- mutation.
local probe = {}

-- ordered as the UI renders them (matches server_config's KINDS)
probe.KINDS = { "fluid", "energy", "item_count", "item_rate", "inventory", "method" }

-- infrastructure that can never be a sensor target
probe.SKIP_TYPES = {
    modem = true, monitor = true, computer = true, turtle = true,
    speaker = true, printer = true, drive = true,
}

-- capability -> kinds, by the same duck-typing telemetry's readers use:
-- tanks() -> fluid; getEnergy/getEnergyStored -> energy; list() -> the item
-- kinds. `method` polls any numeric zero-arg method, so it applies anywhere.
---@param dev table wrapped peripheral
---@return table kinds set { [kind] = true }
function probe.kinds_for(dev)
    if type(dev) ~= "table" then return {} end
    local kinds = { method = true }
    if type(dev.tanks) == "function" then kinds.fluid = true end
    if type(dev.getEnergy) == "function" or type(dev.getEnergyStored) == "function" then
        kinds.energy = true
    end
    if type(dev.list) == "function" then
        kinds.item_count = true
        kinds.item_rate = true
        kinds.inventory = true
    end
    return kinds
end

-- everything reachable right now, sorted by name:
--   { name, ptype, kinds = {kind=true,...}, methods = {sorted fn names} }
---@return table[]
function probe.scan()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        -- getType can return several types in newer CC; the primary is first
        local ptype = peripheral.getType(name)
        if not probe.SKIP_TYPES[ptype or ""] then
            local ok, dev = pcall(peripheral.wrap, name)
            if ok and type(dev) == "table" then
                local methods = {}
                for k, v in pairs(dev) do
                    if type(v) == "function" then table.insert(methods, k) end
                end
                table.sort(methods)
                table.insert(out, {
                    name = name,
                    ptype = ptype or "?",
                    kinds = probe.kinds_for(dev),
                    methods = methods,
                })
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- "minecraft:barrel_2" -> "barrel_2"; side names ("top") pass through
---@param pname string peripheral name
---@return string
function probe.suggest_name(pname)
    return tostring(pname):match("([^:]+)$") or tostring(pname)
end

-- unit prefill per kind (nil = don't assume)
local UNITS = { fluid = "mB", energy = "FE", item_count = "items",
                inventory = "items", item_rate = "items/m" }
---@param kind string
---@return string|nil
function probe.default_unit(kind) return UNITS[kind] end

return probe
