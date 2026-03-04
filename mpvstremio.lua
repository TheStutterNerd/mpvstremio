local mp = require 'mp'
local utils = require 'mp.utils'

-- Points to the bridge binary
local BRIDGE_PATH = mp.command_native({"expand-path", "~~/stremio-bridge"})
local last_query = ""

-- 1. Helper: Display results in a uosc menu
local function display_list_results(res, title_text)
    local items = {}
    if res and res.status == 0 and res.stdout then
        for line in res.stdout:gmatch("[^\r\n]+") do
            local line_type, id, name = line:match("([^|]+)|([^|]+)|(.+)")
            if id then
                local cmd = (line_type == "series") and "stremio-list-episodes" or "stremio-play-movie"
                table.insert(items, { title = name, value = "script-message " .. cmd .. " " .. id })
            end
        end
    end
    if #items == 0 then table.insert(items, { title = "No results found", value = "ignore" }) end
    
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "stremio_list_v3", 
        title = title_text, 
        items = items, 
        keep_open = true 
    }))
end

-- 2. Trakt Handlers (Triggered ONLY on click)
mp.register_script_message("stremio-trakt-trending", function(stype)
    mp.osd_message("Fetching Trending " .. stype .. "...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "trending", stype} }, 
    function(s, res) display_list_results(res, "Trending " .. stype:upper()) end)
end)

mp.register_script_message("stremio-trakt-watchlist", function(stype)
    mp.osd_message("Syncing Trakt " .. stype .. "...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "watchlist", stype} }, 
    function(s, res) display_list_results(res, "Trakt Watchlist: " .. stype:upper()) end)
end)

mp.register_script_message("stremio-trakt-history", function()
    mp.osd_message("Syncing Trakt History...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "history"} }, 
    function(s, res) display_list_results(res, "Recently Watched") end)
end)

-- 3. Search & Episode Logic
mp.register_script_message("stremio-search-type-callback", function(stype, ...)
    local query = table.concat({...}, " ")
    if query == "" then return end
    last_query = query
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "search", stype, query} }, 
    function(s, res) if query == last_query then display_list_results(res, stype:upper() .. ": " .. query) end end)
end)

mp.register_script_message("stremio-list-episodes", function(id)
    mp.osd_message("Loading episodes...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "episodes", id} }, 
    function(s, res)
        local items = {}
        if res and res.status == 0 and res.stdout then
            for line in res.stdout:gmatch("[^\r\n]+") do
                local eid, title = line:match("([^|]+)|(.+)")
                if eid then table.insert(items, { title = title, value = "script-message stremio-play-series " .. eid }) end
            end
        end
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_eps", title = "Select Episode", items = items }))
    end)
end)

-- 4. Playback Engine
local function play(stype, id)
    mp.osd_message("Fetching Stream...", 5)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "stream", stype, id} }, 
    function(s, res)
        if not s or res.status ~= 0 or not res.stdout then mp.osd_message("Error", 3) return end
        local url = ""
        for line in res.stdout:gmatch("[^\r\n]+") do if line:find("http") == 1 or line:find("magnet") == 1 then url = line:gsub("%s+", "") end end
        if url ~= "" then mp.commandv("loadfile", url, "replace") else mp.osd_message("No link found", 3) end
    end)
end

mp.register_script_message("stremio-play-movie", function(id) play("movie", id) end)
mp.register_script_message("stremio-play-series", function(id) play("series", id) end)
mp.register_script_message("stremio-category-select", function(stype)
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_results", title = "Search " .. stype, items = {}, search_style = "submit", on_search = "script-message stremio-search-type-callback " .. stype }))
end)

-- 5. The Main Keybinding (Protected and Explicitly Built)
mp.add_key_binding(nil, "stremio-menu", function()
    local main_menu = {
        type = "stremio_main_v3",
        title = "Stremio",
        items = {
            { title = "Search Movies", value = "script-message stremio-category-select movie" },
            { title = "Search Shows", value = "script-message stremio-category-select series" },
            { title = "Recently Watched", value = "script-message stremio-trakt-history" },
            { title = "---", value = "ignore" },
            { title = "Trending Movies", value = "script-message stremio-trakt-trending movies" },
            { title = "Trending Shows", value = "script-message stremio-trakt-trending shows" },
            { title = "---", value = "ignore" },
            { title = "Trakt Movie Watchlist", value = "script-message stremio-trakt-watchlist movies" },
            { title = "Trakt Show Watchlist", value = "script-message stremio-trakt-watchlist shows" }
        }
    }
    
    -- Safe execution to prevent partial menu renders
    local success, err = pcall(function()
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(main_menu))
    end)
    if not success then mp.msg.error("Stremio Menu Error: " .. tostring(err)) end
end)
