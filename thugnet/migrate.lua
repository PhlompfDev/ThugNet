-- One-shot v1 -> v2 file migration. Idempotent: skips any conversion whose
-- v2 output already exists or whose v1 input is missing. Originals are
-- renamed *.v1.bak, never deleted. (Editor elements migrate in Phase 6.)
local migrate = {}

-- v1 bundled table {["colors.red"]=true} -> v2 name array {"red"}
local function conv_bundled(bundled)
    if type(bundled) == "string" then bundled = { [bundled] = true } end
    if type(bundled) ~= "table" then return nil end
    local names = {}
    for key, active in pairs(bundled) do
        if active then
            local name = type(key) == "string" and (key:match("^colors%.(.+)$") or key)
            if name then table.insert(names, name) end
        end
    end
    table.sort(names)
    if #names == 0 then return nil end
    return names
end

-- v1 faces table -> v2 redstone-step faces table
local function conv_faces(faces)
    local out = {}
    for side, face in pairs(faces or {}) do
        if face.mode == "static" or face.mode == "pulse" then
            local f = { mode = face.mode, bundled = conv_bundled(face.bundled) }
            if face.mode == "pulse" then f.duration_ticks = face.duration or 10 end
            if face.mode == "static" and not face.state_off then f.on = true end
            out[side] = f
        end
    end
    if next(out) == nil then return nil end
    return out
end

-- v1 data_source type -> v2 sensor kind
local KIND_MAP = { fluid = "fluid", energy = "energy", item = "item_count" }

local function conv_server_config(v1)
    local v2 = {
        domain = v1.domain or "myserver",
        dead = (type(v1.settings) == "table" and v1.settings.dead) or false,
        commands = {},
        sensors = {},
    }
    for _, cmd in ipairs(v1.commands or {}) do
        if type(cmd.data_source) == "table" then
            -- data-source command becomes a sensor
            table.insert(v2.sensors, {
                name = cmd.name,
                peripheral = cmd.data_source.peripheral,
                kind = KIND_MAP[cmd.data_source.type] or "method",
                method = cmd.data_source.method,
                poll_secs = 2,
            })
        else
            local steps = {}
            local faces = conv_faces(cmd.faces)
            if faces then table.insert(steps, { type = "redstone", faces = faces }) end
            for _, s in ipairs(cmd.sequence or {}) do
                local sf = conv_faces(s.faces)
                if sf then
                    table.insert(steps, {
                        type = "redstone", faces = sf,
                        delay_ticks = (s.delay and s.delay > 0) and s.delay or nil,
                        name = s.name,
                    })
                end
            end
            table.insert(v2.commands, {
                name = cmd.name,
                response_key = cmd.response_key,
                steps = steps,
            })
        end
    end
    return v2
end

---@param store table core/store module
---@return table result { migrated = string[] }
function migrate.run(store)
    local migrated = {}

    -- Real CC:Tweaked fs.move ERRORS when the destination exists (the offline stub
    -- silently overwrites, so a test cannot catch this). A pre-existing .v1.bak --
    -- from a user restoring a backup by copying files back, or a v1 install re-run
    -- over a migrated node -- would make the move fail, the pcall swallow it, and
    -- the caller then overwrite the original anyway. Find a free name instead.
    ---@return boolean ok false when the original could not be preserved
    local function bak(path)
        local dest = path .. ".v1.bak"
        local n = 2
        while fs.exists(dest) do
            dest = path .. ".v1.bak." .. n
            n = n + 1
            if n > 50 then return false end
        end
        return (pcall(fs.move, path, dest)) == true
    end

    -- server config
    if fs.exists("server_config.json") and not fs.exists("server_config2.json") then
        local v1 = store.load("server_config.json", nil)
        if v1 then
            store.save("server_config2.json", conv_server_config(v1))
            bak("server_config.json")
            table.insert(migrated, "server_config")
        end
    end

    -- dns registry
    if fs.exists("domains.json") and not fs.exists("dns_registry2.json") then
        local v1 = store.load("domains.json", nil)
        if v1 then
            local v2 = {}
            for domain, id in pairs(v1) do
                if type(id) == "number" then v2[domain] = { id = id } end
            end
            store.save("dns_registry2.json", v2)
            bak("domains.json")
            table.insert(migrated, "dns_registry")
        end
    end

    -- custom pages: v1 wrote a bare array of { name, visibility } with no ids --
    -- they were positional dyn_N computed at render time. The i-th entry
    -- therefore becomes custom_i, so Phase 6b can map dyn_N -> custom_N when it
    -- migrates editor_elements.json. Index order is the whole contract here.
    -- Self-guarding: after conversion the file is an object, so v1[1] is nil.
    -- Whether custom_pages.json was unreadable THIS run. store.load quarantines it
    -- to .corrupt on the first read, so a later load in the same run just sees an
    -- absent file -- the editor-elements block below cannot rediscover this itself.
    local custom_pages_corrupt = false

    if fs.exists("custom_pages.json") then
        local v1, was_corrupt = store.load("custom_pages.json", nil)
        custom_pages_corrupt = was_corrupt == true
        if type(v1) == "table" and v1[1] ~= nil then
            local pages = {}
            for i, e in ipairs(v1) do
                if type(e) == "table" and type(e.name) == "string" then
                    table.insert(pages, { id = "custom_" .. i, name = e.name })
                end
            end
            -- same path in and out: back the original up before reusing it, and
            -- clear every index ever issued (including entries dropped above)
            bak("custom_pages.json")
            store.save("custom_pages.json", { next_seq = #v1 + 1, pages = pages })
            table.insert(migrated, "custom_pages")
        end
    end

    -- editor elements: v1 stored colours as raw CC numbers and keyed pages by
    -- "default" / "dyn_N" / the built-in page ids. v2 stores colour NAMES and only
    -- custom pages are editable, so every v1 page holding elements is rehomed onto
    -- a custom page rather than dropped -- silently discarding placed widgets is
    -- not acceptable. dyn_N -> custom_N holds because the custom_pages conversion
    -- above assigned the i-th v1 entry custom_i, so this block must stay after it.
    if fs.exists("editor_elements.json") then
        local v1 = store.load("editor_elements.json", nil)
        local needs = false
        if type(v1) == "table" then
            for page_id, defs in pairs(v1) do
                -- keys come from JSON, but guard anyway: a v1 file that round-tripped
                -- as an array would hand us numbers here and :match would throw
                if type(page_id) == "string" and page_id ~= "default"
                   and not page_id:match("^custom_%d+$") then needs = true end
                if type(defs) == "table" then
                    for _, d in ipairs(defs) do
                        if type(d) == "table" and (type(d.fg) == "number" or d.colors ~= nil
                           -- a 6b-migrated install upgrading to 6c has files whose
                           -- ONLY v1-ism is a stale route -- 6b's migration preserved
                           -- unknown fields while consuming every other trigger
                           or d.route == "dns" or d.route == "client") then
                            needs = true
                        end
                    end
                end
            end
            if v1.default ~= nil then needs = true end
        end

        local cp, reload_corrupt = store.load("custom_pages.json", { next_seq = 1, pages = {} })
        local cp_corrupt = custom_pages_corrupt or reload_corrupt == true

        -- A corrupt custom_pages.json is salvaged by custom_pages.init later in this
        -- same boot -- it regex-scans the quarantined text for the id high-water mark
        -- precisely so ids are never reissued. Rewriting the file here would hand it
        -- a VALID file instead, the salvage would never run, next_seq would restart
        -- at 1, and live ids would be reissued. Leave v1 alone and migrate on the
        -- next boot, once the ids are safe again.
        if cp_corrupt then needs = false end

        if needs then
            local cmap = require("thugnet.ui.editor.colors")
            local COLOR_FIELDS = { "fg", "bg", "afg", "abg",
                                   "radio_a", "radio_b", "select_color", "bar_fg", "bar_bg" }
            local RENAMED = { ["controls"] = "Controls (v1)", ["reactor"] = "Reactor (v1)",
                              ["dns"] = "DNS (v1)", ["client"] = "Client (v1)",
                              ["server"] = "Server (v1)", ["default"] = "Custom" }

            if type(cp.pages) ~= "table" then cp.pages = {} end
            if type(cp.next_seq) ~= "number" then cp.next_seq = 1 end

            local known = {}      -- ids already present in custom_pages.json
            for _, p in ipairs(cp.pages) do
                if type(p) == "table" and type(p.id) == "string" then known[p.id] = true end
            end

            -- Pass 1: page keys that carry their own number keep it, and next_seq is
            -- raised above every one of them. custom_pages.init derives next_seq
            -- ONLY from custom_pages.json and never looks at editor_elements.json,
            -- so a dyn_5 -> custom_5 rehome that left next_seq at 1 would let the
            -- next page the user creates be issued custom_5 -- opening already full
            -- of a dead v1 page's widgets. That is the exact id-reuse bug phase 6a
            -- exists to prevent.
            local targets, taken, leftover = {}, {}, {}
            for page_id, defs in pairs(v1) do
                -- an empty v1 page carries no user work, so it earns no rehomed page
                if type(page_id) == "string" and type(defs) == "table" and #defs > 0 then
                    local n = page_id:match("^dyn_(%d+)$") or page_id:match("^custom_(%d+)$")
                    local target = n and ("custom_" .. n) or nil
                    if target and not taken[target] then
                        targets[page_id], taken[target] = target, true
                        local num = tonumber(n)
                        if num and num >= cp.next_seq then cp.next_seq = num + 1 end
                    else
                        -- no number of its own, or two v1 keys claiming one id
                        table.insert(leftover, page_id)
                    end
                end
            end

            -- sorted, so the ids issued below do not depend on pairs() order
            table.sort(leftover)

            -- Pass 2: everything else gets a brand new page. Assigning into `out`
            -- was previously a plain overwrite, so two v1 keys landing on one id
            -- silently destroyed one page's widgets depending on iteration order.
            for _, page_id in ipairs(leftover) do
                local target = "custom_" .. cp.next_seq
                cp.next_seq = cp.next_seq + 1
                targets[page_id], taken[target] = target, true
                table.insert(cp.pages, { id = target, name = RENAMED[page_id] or page_id })
                known[target] = true
            end

            local out = {}
            for page_id, target in pairs(targets) do
                -- a dyn_N whose page was deleted in v1 has elements but no page
                -- entry; give it one rather than orphaning the widgets under an id
                -- nothing renders
                if not known[target] then
                    table.insert(cp.pages, { id = target, name = RENAMED[page_id] or page_id })
                    known[target] = true
                end

                local kept = {}
                for _, d in ipairs(v1[page_id]) do
                    if type(d) == "table" and type(d.type) == "string" then
                        for _, f in ipairs(COLOR_FIELDS) do
                            if type(d[f]) == "number" then d[f] = cmap.to_name(d[f]) end
                        end
                        -- v1's `colors` was an LED scheme KEY string, not a colour
                        if d.colors ~= nil then d.scheme = d.colors; d.colors = nil end
                        -- v1 route dns/client was a transport choice v2 collapsed
                        -- into client.send; both mean the default command path
                        if d.route == "dns" or d.route == "client" then d.route = nil end
                        d.x = tonumber(d.x) or 1
                        d.y = tonumber(d.y) or 1
                        table.insert(kept, d)
                    end
                end
                out[target] = kept
            end

            store.save("custom_pages.json", cp)
            bak("editor_elements.json")
            store.save("editor_elements.json", out)
            table.insert(migrated, "editor_elements")
        end
    end

    -- ui state
    if fs.exists("demo_state.json") and not fs.exists("state.json") then
        local v1 = store.load("demo_state.json", nil)
        if v1 then
            store.save("state.json", v1)
            bak("demo_state.json")
            table.insert(migrated, "state")
        end
    end

    return { migrated = migrated }
end

return migrate
