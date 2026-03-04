local mp = require 'mp'
local utils = require 'mp.utils'

local BRIDGE_PATH = mp.command_native({"expand-path", "~~/stremio-bridge"})
local last_query = ""
local current_id = nil
local current_type = nil
local scrobbled = false

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
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_list_v3", title = title_text, items = items, keep_open = true }))
end

-- Trakt Handlers
mp.register_script_message("stremio-trakt-trending", function(stype)
    mp.osd_message("Fetching Trending " .. stype .. "...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "trending", stype} }, function(s, res) display_list_results(res, "Trending " .. stype:upper()) end)
end)

mp.register_script_message("stremio-trakt-watchlist", function(stype)
    mp.osd_message("Syncing Trakt " .. stype .. "...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "watchlist", stype} }, function(s, res) display_list_results(res, "Trakt Watchlist: " .. stype:upper()) end)
end)

mp.register_script_message("stremio-trakt-history", function()
    mp.osd_message("Syncing Trakt History...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "history"} }, function(s, res) display_list_results(res, "Recently Watched") end)
end)

-- Playback logic with Scrobble Tracking
local function play(stype, id)
    current_id = id
    current_type = stype
    scrobbled = false
    
    -- FORCE MPV to ignore its local memory for this file
    mp.set_property_bool("save-position-on-quit", false)
    mp.set_property("watch-later-directory", "")
    
    mp.osd_message("Fetching Stream...", 5)
    
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "stream", stype, id} }, function(s, res)
        if not s or res.status ~= 0 or not res.stdout then return end
        
        local url = ""
        for line in res.stdout:gmatch("[^\r\n]+") do 
            if line:find("http") == 1 or line:find("magnet") == 1 then url = line:gsub("%s+", "") end
        end
        
        if url ~= "" then
            mp.commandv("loadfile", url, "replace")
            
            -- Wait for file to load, then check Trakt progress
            mp.add_timeout(1, function()
                mp.command_native_async({ name = "subprocess", capture_stdout = true, args = {BRIDGE_PATH, "get-progress", stype, id} }, function(s2, res2)
                    if res2 and res2.stdout ~= "" then
                        local progress = tonumber(res2.stdout)
                        if progress and progress > 1 and progress < 90 then
                            -- Create the uosc menu
                            local resume_menu = {
                                type = "stremio_resume",
                                title = "Resume from " .. math.floor(progress) .. "%?",
                                items = {
                                    { title = "Yes, Resume", value = "script-message stremio-do-resume " .. progress }, 
                                    { title = "No, Start Over", value = "ignore" }
                                }
                            }
                            -- Ensure the JSON is formatted correctly for uosc
                            mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(resume_menu))
                        end
                    end
                end)
            end)
        end
    end)
end

-- Listener for the Resume Menu selection
mp.register_script_message("stremio-do-resume", function(percent_str)
    local p = tonumber(percent_str)
    if not p then return end

    -- We use a small delay to let the stream initialize
    mp.add_timeout(0.5, function()
        local duration = mp.get_property_number("duration")
        if duration and duration > 0 then
            local seek_time = (p / 100) * duration
            mp.commandv("seek", seek_time, "absolute", "exact")
        else
            -- Fallback if duration isn't available yet
            mp.set_property_number("percent-pos", p)
        end
        mp.osd_message("Resumed to " .. math.floor(p) .. "%", 3)
    end)
end)

-- SCROBBLE OBSERVER: Checks every 60 seconds
mp.add_periodic_timer(60, function()
    if scrobbled or not current_id or not current_type then return end
    local pos = mp.get_property_number("percent-pos", 0)
    if pos > 85 then -- Sync once you've watched 85%
        mp.command_native_async({
            name = "subprocess", playback_only = false,
            args = {BRIDGE_PATH, "scrobble", current_type, current_id}
        }, function() 
            scrobbled = true 
            mp.osd_message("Trakt: Watch History Synced", 3)
        end)
    end
end)

mp.register_script_message("stremio-trakt-collection", function(stype)
    mp.osd_message("Opening Library: " .. stype:upper() .. "...", 2)
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {BRIDGE_PATH, "collection", stype}
    }, function(s, res)
        display_list_results(res, "Trakt Library: " .. stype:upper())
    end)
end)

mp.register_script_message("stremio-search-type-callback", function(stype, ...)
    local query = table.concat({...}, " ")
    if query == "" then return end
    last_query = query
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "search", stype, query} }, function(s, res)
        if query == last_query then display_list_results(res, stype:upper() .. ": " .. query) end
    end)
end)

mp.register_script_message("stremio-list-episodes", function(id)
    mp.osd_message("Loading episodes...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "episodes", id} }, function(s, res)
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

mp.register_script_message("stremio-play-movie", function(id) play("movie", id) end)
mp.register_script_message("stremio-play-series", function(id) play("episode", id) end)
mp.register_script_message("stremio-category-select", function(stype)
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_results", title = "Search " .. stype, items = {}, search_style = "submit", on_search = "script-message stremio-search-type-callback " .. stype }))
end)

mp.add_key_binding(nil, "stremio-menu", function()
    local main_menu = {
        type = "stremio_main_v3",
        title = "Stremio",
        items = {
            { title = "Search Movies", value = "script-message stremio-category-select movie" },
            { title = "Search Shows", value = "script-message stremio-category-select series" },
            { title = "Recently Watched", value = "script-message stremio-trakt-history" },
            { title = "Movie Library", value = "script-message stremio-trakt-collection movies" },
            { title = "Show Library", value = "script-message stremio-trakt-collection shows" },
            { title = "Trending Movies", value = "script-message stremio-trakt-trending movies" },
            { title = "Trending Shows", value = "script-message stremio-trakt-trending shows" },
            { title = "Trakt Movie Watchlist", value = "script-message stremio-trakt-watchlist movies" },
            { title = "Trakt Show Watchlist", value = "script-message stremio-trakt-watchlist shows" }
        }
    }
    pcall(function() mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(main_menu)) end)
end)

-- SYNC ON QUIT: Reports progress when closing
mp.register_event("shutdown", function()
    if not scrobbled and current_id and current_type then
        local pos = mp.get_property_number("percent-pos")
        -- Changed to 5% to 85% to keep your Trakt history clean
        if pos and pos > 5 and pos < 85 then
            mp.command_native({
                name = "subprocess",
                playback_only = false,
                args = {BRIDGE_PATH, "progress", current_type, current_id, tostring(pos)}
            })
        end
    end
end)
