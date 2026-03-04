local mp = require 'mp'
local utils = require 'mp.utils'

-- Points directly to ~/.config/mpv/stremio-bridge
local BRIDGE_PATH = mp.command_native({"expand-path", "~~/stremio-bridge"})
local last_query = ""

-- Generic function to display list results (used for Search, Watchlist, and History)
local function display_list_results(res, title_text)
    local items = {}
    if res.status == 0 and res.stdout then
        for line in res.stdout:gmatch("[^\r\n]+") do
            local line_type, id, name = line:match("([^|]+)|([^|]+)|(.+)")
            if id then
                local cmd = (line_type == "series") and "stremio-list-episodes" or "stremio-play-movie"
                table.insert(items, { 
                    title = name, 
                    value = "script-message " .. cmd .. " " .. id 
                })
            end
        end
    end
    
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "stremio_list", 
        title = title_text, 
        items = items,
        keep_open = true
    }))
end

-- Search function that calls the Go bridge
local function perform_search(stype, query)
    if not query or query == "" then return end
    last_query = query
    
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {BRIDGE_PATH, "search", stype, query}
    }, function(success, res)
        if query ~= last_query then return end
        
        local items = {}
        if success and res.status == 0 and res.stdout then
            for line in res.stdout:gmatch("[^\r\n]+") do
                local line_type, id, name = line:match("([^|]+)|([^|]+)|(.+)")
                if id then
                    local cmd = (line_type == "series") and "stremio-list-episodes" or "stremio-play-movie"
                    table.insert(items, { 
                        title = name, 
                        value = "script-message " .. cmd .. " " .. id 
                    })
                end
            end
        end
        
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
            type = "stremio_results", 
            title = stype:upper() .. " Results: " .. query, 
            items = items,
            search_style = "submit",
            search_delay = 1000,
            keep_open = true,
            on_search = "script-message stremio-search-type-callback " .. stype
        }))
    end)
end

-- Trakt Watchlist Function
mp.register_script_message("stremio-trakt-watchlist", function(stype)
    mp.osd_message("Syncing Trakt " .. stype .. "...", 2)
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {BRIDGE_PATH, "watchlist", stype}
    }, function(success, res)
        display_list_results(res, "Trakt Watchlist: " .. stype:upper())
    end)
end)

-- Trakt History Function
mp.register_script_message("stremio-trakt-history", function()
    mp.osd_message("Syncing Trakt History...", 2)
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {BRIDGE_PATH, "history"}
    }, function(success, res)
        display_list_results(res, "Recently Watched")
    end)
end)

-- Stream fetching and playback logic
local function play(stype, id)
    mp.osd_message("Fetching Stream...", 5)
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {BRIDGE_PATH, "stream", stype, id}
    }, function(success, res)
        if not success or res.status ~= 0 or not res.stdout then 
            mp.osd_message("Error fetching stream", 3) return 
        end
        local url = ""
        for line in res.stdout:gmatch("[^\r\n]+") do
            local clean = line:gsub("^%s+", ""):gsub("%s+$", "")
            if clean:find("http") == 1 or clean:find("magnet") == 1 then url = clean end
        end
        if url ~= "" then mp.commandv("loadfile", url, "replace") else mp.osd_message("No link found", 3) end
    end)
end

-- Handlers for search callbacks and episode listing
mp.register_script_message("stremio-search-type-callback", function(stype, ...)
    local arg = {...}
    local query = table.concat(arg, " ")
    perform_search(stype, query)
end)

mp.register_script_message("stremio-list-episodes", function(id)
    mp.osd_message("Loading episodes...", 2)
    local res = mp.command_native({ 
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {BRIDGE_PATH, "episodes", id} 
    })
    local items = {}
    if res.status == 0 and res.stdout then
        for line in res.stdout:gmatch("[^\r\n]+") do
            local pipe_idx = line:find("|")
            if pipe_idx then
                local eid = line:sub(1, pipe_idx - 1)
                local full_title = line:sub(pipe_idx + 1)
                table.insert(items, { title = full_title, value = "script-message stremio-play-series " .. eid })
            end
        end
    end
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_eps", title = "Select Episode", items = items }))
end)

mp.register_script_message("stremio-play-movie", function(id) play("movie", id) end)
mp.register_script_message("stremio-play-series", function(id) play("series", id) end)

-- Category Selection
mp.register_script_message("stremio-category-select", function(stype)
    last_query = ""
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "stremio_results",
        title = "Search " .. (stype == "movie" and "Movies" or "Shows"),
        items = {},
        search_style = "submit",
        search_delay = 1000,
        on_search = "script-message stremio-search-type-callback " .. stype
    }))
end)

-- Main Menu Binding
mp.add_key_binding(nil, "stremio-menu", function()
    local menu = {
        type = "stremio_main",
        title = "Stremio",
        items = {
            { title = "Search Movies", value = "script-message stremio-category-select movie" },
            { title = "Search Shows", value = "script-message stremio-category-select series" },
            { title = "Recently Watched", value = "script-message stremio-trakt-history" },
            { title = "---", value = "ignore" },
            { title = "Trakt Movie Watchlist", value = "script-message stremio-trakt-watchlist movies" },
            { title = "Trakt Show Watchlist", value = "script-message stremio-trakt-watchlist shows" }
        }
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end)
