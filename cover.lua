-- cover: an album art pane for cliamp.
--
-- The plugin takes a pane in the visualizer band (or the settings column) and
-- draws the cover of the current track. Two renderers:
--
--   image  the core transmits the cover to the terminal and hands back Unicode
--          placeholders (kitty graphics protocol); the image is the real cover.
--   blocks the same cover as ANSI half-block art, so it works in any terminal.
--
-- Alt+G opens its own menu: width, position, region, renderer, and which
-- visualizer the pane shows. No core option is involved: the pane is composed
-- through cliamp.layout and cliamp.image.

local p = plugin.register({
    name        = "cover",
    type        = "visualizer",
    version     = "1.0.0",
    description = "Album art pane: kitty image or ANSI blocks",
    permissions = {"image", "layout", "ui", "keymap"},
})

local art = ""
-- One image per pane size: two panes of this plugin never share a placement.
local images = {}
local blocks = {}

local state = { pct = 40, position = "after", vis = "", region = "visualizer", mode = "image" }
local stay = true
local dirty = false

local function clearImages()
    for _, entry in pairs(images) do
        pcall(cliamp.image.clear, entry.id)
    end
    images = {}
end

local function setArt(url)
    if not url or url == "" or url == art then
        return
    end
    art = url
    -- The image is not deleted: the next render re-transmits it to the same id
    -- and the terminal swaps the pixels, so there is no frame with a placement
    -- that points at a deleted image.
    dirty = true
end

p:on("track.change", function(track)
    setArt(track.album_art_url)
end)

-- The first track.change can arrive before the provider resolves the cover (a
-- Telegram cover is extracted while the file downloads). playback.state fires
-- once per second, so it fills the art without waiting for the next track.
p:on("playback.state", function(state)
    if art == "" then
        setArt(state.album_art_url)
    end
end)

p:on("app.quit", clearImages)

-- ensureImage returns the placement for this pane size, transmitting the cover
-- when it is missing or changed.
local function ensureImage(cols, rows)
    if art == "" or cols < 4 or rows < 2 then
        return nil
    end
    local key = rows .. "x" .. cols
    local entry = images[key]
    if not entry then
        -- The pane changes size with the layout. The old placement would stay
        -- on screen (as a floating strip) until something deletes it.
        local stale = false
        for _ in pairs(images) do
            stale = true
            break
        end
        if stale then
            clearImages()
        end
    end
    if entry then
        if dirty then
            cliamp.image.show(art, { cols = entry.cols, rows = entry.rows, id = entry.id })
            dirty = false
        end
        return entry
    end
    -- Keep the cover square: cells are roughly 1:2 wide:tall, so a square in
    -- pixels is two columns per row. When the pane is narrow, use fewer rows
    -- instead of stretching the image.
    -- Two cells of slack: a block as wide as the pane hits the frame edge, the
    -- line wraps and the placeholders break apart.
    local usableCols = math.max(2, cols - 2)
    local coverRows = math.min(rows, math.floor(usableCols / 2))
    local coverCols = math.min(usableCols, coverRows * 2)
    coverRows = math.max(1, math.floor(coverCols / 2))
    local id = cliamp.image.show(art, { cols = coverCols, rows = coverRows })
    dirty = false
    if not id then
        art = ""
        return nil
    end
    entry = { id = id, cols = coverCols, rows = coverRows }
    images[key] = entry
    return entry
end

-- Text mode: the cover as ANSI half blocks, no graphics protocol needed.
local function renderBlocks(cols, rows)
    if art == "" or cols < 4 or rows < 2 then
        return ""
    end
    -- Two cells of slack, same reason as above.
    local width = math.max(2, cols - 2)
    local key = rows .. "x" .. width
    local cached = blocks[key]
    if cached then
        return cached
    end
    local text = cliamp.image.blocks(art, { cols = width, rows = rows })
    if not text then
        return ""
    end
    blocks[key] = text
    return text
end

function p:render(bands, frame, rows, cols)
    -- Ask the core for the cover of the current playback state on every frame:
    -- that removes any dependency on the order of track.change and
    -- playback.state.
    local current = cliamp.track.album_art_url()
    if current and current ~= "" and current ~= art then
        setArt(current)
        blocks = {}
    end

    if state.mode == "blocks" then
        return renderBlocks(cols, rows)
    end

    local entry = ensureImage(cols, rows)
    if not entry then
        return ""
    end
    local block = cliamp.image.block(entry.id)
    if not block then
        return ""
    end
    local coverLines = {}
    for line in (block .. "\n"):gmatch("(.-)\n") do
        table.insert(coverLines, line)
    end
    local padLeft = math.max(0, math.floor((cols - entry.cols) / 2))
    local padTop = math.max(0, math.floor((rows - entry.rows) / 2))
    local out = {}
    for row = 1, rows do
        local index = row - padTop
        local line = ""
        if index >= 1 and index <= #coverLines then
            line = string.rep(" ", padLeft) .. coverLines[index]
        end
        -- Exactly cols cells: the core neither truncates nor pads, and the line
        -- never crosses the pane edge (which is what wrapped and broke it).
        local width = padLeft + (line ~= "" and entry.cols or 0)
        if width < cols then
            line = line .. string.rep(" ", cols - width)
        end
        out[row] = line
    end
    return table.concat(out, "\n")
end

function p:destroy()
    clearImages()
end

local function stored(key, fallback)
    local value = cliamp.store.get("cover." .. key)
    if value == nil then return fallback end
    return value
end

local function persist()
    cliamp.store.set("cover.pct", state.pct)
    cliamp.store.set("cover.position", state.position)
    cliamp.store.set("cover.vis", state.vis)
    cliamp.store.set("cover.region", state.region)
    cliamp.store.set("cover.mode", state.mode)
end

-- applyPane rebuilds the pane from state: it removes both regions first, so the
-- plugin owns at most one pane at a time.
local function applyPane()
    -- Geometry changes: the old placements would float over the text.
    clearImages()

    cliamp.layout.remove({ region = "visualizer", pane = "cover" })
    cliamp.layout.remove({ region = "settings", pane = "cover" })
    cliamp.layout.set_builtin({ region = "visualizer", enabled = true })
    cliamp.layout.set_builtin({ region = "settings", enabled = true })
    cliamp.layout.set_weight({ region = "visualizer", pane = "builtin", weight = 1 })
    cliamp.layout.set_weight({ region = "settings", pane = "builtin", weight = 1 })

    if state.pct <= 0 then
        persist()
        return
    end

    local region = state.region
    if state.pct >= 100 then
        cliamp.layout.set_builtin({ region = region, enabled = false })
        cliamp.layout.add({ region = region, pane = "cover", weight = 1, position = state.position })
    else
        cliamp.layout.set_weight({ region = region, pane = "builtin", weight = 100 - state.pct })
        cliamp.layout.add({
            region = region,
            pane = "cover",
            weight = state.pct,
            position = state.position,
        })
    end
    if state.vis ~= "" then
        cliamp.layout.set_vis({ region = region, pane = "cover", vis = state.vis })
    end
    persist()
end

local openMenu

local function pickVisualizer(target, cursor)
    local names = cliamp.vis.list()
    cliamp.ui.select({
        title = target == "builtin" and "Visualizer of the builtin pane" or "Visualizer of this pane",
        options = names,
        cursor = cursor or 1,
        on_select = function(index)
            local choice = names[index]
            if not choice then return end
            if target == "builtin" then
                cliamp.vis.set(choice)
            else
                state.vis = choice
                applyPane()
            end
            if stay then pickVisualizer(target, index) end
        end,
        on_cancel = function()
            if stay then openMenu(target == "builtin" and 6 or 5) end
        end,
    })
end

openMenu = function(cursor)
    cliamp.ui.select({
        title = string.format("Cover pane — %s %d%%", state.region, state.pct),
        cursor = cursor or 1,
        options = {
            "grow +10%",
            "shrink -10%",
            "move before the builtin",
            "move after the builtin",
            "visualizer of this pane...",
            "visualizer of the builtin pane...",
            state.region == "visualizer" and "region: visualizer (switch to settings)" or "region: settings (switch to visualizer)",
            state.mode == "image" and "mode: kitty image (switch to blocks)" or "mode: blocks (switch to image)",
            "remove pane",
        },
        on_select = function(index)
            if index == 1 then
                state.pct = math.min(100, state.pct + 10)
                applyPane()
            elseif index == 2 then
                state.pct = math.max(0, state.pct - 10)
                applyPane()
            elseif index == 3 then
                state.position = "before"
                applyPane()
            elseif index == 4 then
                state.position = "after"
                applyPane()
            elseif index == 5 then
                pickVisualizer("cover")
                return
            elseif index == 6 then
                pickVisualizer("builtin")
                return
            elseif index == 7 then
                state.region = state.region == "visualizer" and "settings" or "visualizer"
                applyPane()
            elseif index == 8 then
                state.mode = state.mode == "image" and "blocks" or "image"
                blocks = {}
                applyPane()
            elseif index == 9 then
                clearImages()
                cliamp.layout.remove({ region = "visualizer", pane = "cover" })
                cliamp.layout.remove({ region = "settings", pane = "cover" })
                cliamp.layout.set_builtin({ region = "visualizer", enabled = true })
                cliamp.layout.set_builtin({ region = "settings", enabled = true })
                cliamp.layout.set_weight({ region = "visualizer", pane = "builtin", weight = 1 })
                cliamp.layout.set_weight({ region = "settings", pane = "builtin", weight = 1 })
                return
            end
            if stay then openMenu(index) end
        end,
    })
end

p:bind("alt+g", function() openMenu(1) end)

p:on("app.start", function()
    local configured = p:config("stay")
    if configured ~= nil then
        stay = tostring(configured) ~= "false" and tostring(configured) ~= "0"
    end
    state.pct = tonumber(stored("pct", 40)) or 40
    state.position = stored("position", "after")
    state.vis = stored("vis", "")
    state.region = stored("region", "visualizer")
    state.mode = stored("mode", "image")
    applyPane()
end)
