-- The 16 CC colour slots by name. Element colours are user-picked and stored as
-- NAMES, not numbers: theme.lua retunes the palette, so a def saying "green"
-- renders in whatever green the active theme defines. v1 stored raw numbers,
-- which baked in the old palette.
local colors_map = {}

-- CC palette order, matching the order the colour-pick menu presents them
colors_map.NAMES = {
    "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
    "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}

local by_name, by_value = {}, {}
for _, n in ipairs(colors_map.NAMES) do
    local v = colors[n]
    if v then by_name[n] = v; by_value[v] = n end
end

---@return integer|nil
function colors_map.to_color(name)
    if type(name) ~= "string" then return nil end
    return by_name[name]
end

---@return string|nil
function colors_map.to_name(value)
    if type(value) ~= "number" then return nil end
    return by_value[value]
end

return colors_map
