local mp = require 'mp'
local utils = require 'mp.utils'

-- 1. GLOBAL VARIABLES (At the top so all functions can see them)
local BRIDGE_PATH = mp.command_native({"expand-path", "~~/stremio-bridge"})
local last_query = ""
local current_id = nil
local current_type = nil
local scrobbled = false
local up_next_triggered = false
local last_active_id = nil
local last_active_type = nil
local last_pos = 0

-- 2. UTILITY: Display Results in uosc
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

-- 3. TRAKT HANDLERS
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

mp.register_script_message("stremio-trakt-collection", function(stype)
    mp.osd_message("Opening Library: " .. stype:upper() .. "...", 2)
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "collection", stype} }, function(s, res) display_list_results(res, "Trakt Library: " .. stype:upper()) end)
end)

-- 4. PLAYBACK LOGIC
local function play(stype, id)
    current_id = id
    current_type = stype
    last_active_id = id
    last_active_type = stype
    scrobbled = false
    up_next_triggered = false
    
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
            mp.add_timeout(1, function()
                mp.command_native_async({ name = "subprocess", capture_stdout = true, args = {BRIDGE_PATH, "get-progress", stype, id} }, function(s2, res2)
                    if res2 and res2.stdout ~= "" then
                        local progress = tonumber(res2.stdout)
                        if progress and progress > 1 and progress < 90 then
                            local resume_menu = {
                                type = "stremio_resume",
                                title = "Resume from " .. math.floor(progress) .. "%?",
                                items = {
                                    { title = "Yes, Resume", value = "script-message stremio-do-resume " .. progress }, 
                                    { title = "No, Start Over", value = "ignore" }
                                }
                            }
                            mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(resume_menu))
                        end
                    end
                end)
            end)
        end
    end)
end

-- Resume helper
mp.register_script_message("stremio-do-resume", function(percent_str)
    local p = tonumber(percent_str)
    if not p then return end
    mp.add_timeout(0.5, function()
        local duration = mp.get_property_number("duration")
        if duration and duration > 0 then
            mp.commandv("seek", (p / 100) * duration, "absolute", "exact")
        else
            mp.set_property_number("percent-pos", p)
        end
    end)
end)

-- 5. OBSERVERS (Position Tracking)
mp.observe_property("percent-pos", "number", function(_, val)
    if val and val > 0 then last_pos = val end
end)

-- Periodic scrobble check
mp.add_periodic_timer(10, function()
    if not current_id or not current_type then return end
    local pos = mp.get_property_number("percent-pos", 0)

    -- 1. SCROBBLE LOGIC (Stays the same)
    if not scrobbled and pos > 85 then
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = {BRIDGE_PATH, "scrobble", current_type, current_id} 
        }, function()
            scrobbled = true
            mp.osd_message("Trakt: Watch History Synced", 3)
        end)
    end

    -- 2. AUTO-NEXT PLAYLIST LOGIC
    if current_type == "episode" and pos > 95 and not up_next_triggered then
        local count = mp.get_property_number("playlist-count", 0)
        local current_pos = mp.get_property_number("playlist-pos", 0)

        -- Check if there's actually another episode in the playlist
        if current_pos + 1 < count then
            up_next_triggered = true
            
            -- Show uosc notification
            mp.commandv("script-message-to", "uosc", "show-text", "Up Next: Starting in 10 seconds...", 10)
            
            mp.add_timeout(10, function()
                -- Re-verify we are still near the end before jumping
                local current_pct = mp.get_property_number("percent-pos", 0)
                if current_pct > 90 then
                    mp.command("playlist-next")
                end
            end)
        end
    end
end)

-- 6. SEARCH & MENU
mp.register_script_message("stremio-search-type-callback", function(stype, ...)
    local query = table.concat({...}, " ")
    if query == "" then return end
    last_query = query
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "search", stype, query} }, function(s, res)
        if query == last_query then display_list_results(res, stype:upper() .. ": " .. query) end
    end)
end)

local last_season_data = "" -- Add this to your global variables at the top

mp.register_script_message("stremio-list-episodes", function(id)
    mp.osd_message("Loading episodes...", 2)
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {BRIDGE_PATH, "episodes", id}
    }, function(s, res)
        if res and res.status == 0 and res.stdout then
            -- IMPORTANT: This line must execute before the menu is built
            last_season_data = res.stdout
            
            local items = {}
            for line in last_season_data:gmatch("[^\r\n]+") do
                local eid, title = line:match("([^|]+)|(.+)")
                if eid then
                    table.insert(items, {
                        title = title,
                        value = "script-message stremio-play-series " .. eid
                    })
                end
            end
            mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_eps", title = "Select Episode", items = items }))
        end
    end)
end)

mp.register_script_message("stremio-play-series", function(id)
    if last_season_data == "" then
        mp.osd_message("Error: No season data found", 5)
        return
    end
    
    -- 1. KILL CURRENT PLAYBACK AND CLEAR LIST
    mp.command("stop")
    mp.command("playlist-clear")
    
    -- 2. WAIT A MOMENT FOR MPV TO FLUSH THE OLD STATE
    mp.add_timeout(0.1, function()
        local playlist_index = 0
        local target_index = 0
        
        for line in last_season_data:gmatch("[^\r\n]+") do
            local eid, title = line:match("([^|]+)|(.+)")
            if eid then
                local url = "stremio://episode/" .. eid
                
                -- Always append since we already cleared manually
                mp.commandv("loadfile", url, "append")
                
                -- Manually set the title for the UI
                mp.set_property_native("playlist/" .. playlist_index .. "/title", title)
                
                if eid == id then
                    target_index = playlist_index
                end
                playlist_index = playlist_index + 1
            end
        end

        -- 3. JUMP TO THE SELECTED EPISODE
        mp.set_property_number("playlist-pos", target_index)
        mp.osd_message("Swapping Show: " .. playlist_index .. " episodes loaded", 2)
    end)
end)

mp.register_script_message("stremio-play-movie", function(id) play("movie", id) end)
mp.register_script_message("stremio-category-select", function(stype)
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_results", title = "Search " .. stype, items = {}, search_style = "submit", on_search = "script-message stremio-search-type-callback " .. stype }))
end)

mp.add_key_binding(nil, "stremio-menu", function()
    local items = {
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

    if current_type == "episode" and current_id then
        table.insert(items, 1, { title = "⏭ Skip to Next Episode", value = "script-message stremio-manual-next" })
        table.insert(items, 2, { title = "--------------------------------", value = "ignore" })
    end

    local main_menu = { type = "stremio_main_v4", title = "Stremio", items = items }
    pcall(function() mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(main_menu)) end)
end)

mp.register_script_message("stremio-manual-next", function()
    if not current_id or current_type ~= "episode" then return end
    
    -- Check if there is actually a next item in the playlist
    local count = mp.get_property_number("playlist-count", 0)
    local pos = mp.get_property_number("playlist-pos", 0)
    
    if pos + 1 < count then
        mp.osd_message("Skipping to next episode...", 2)
        mp.commandv("script-message-to", "uosc", "close-menu")
        mp.command("playlist-next")
    else
        mp.osd_message("End of Season", 3)
    end
end)

-- 7. EVENTS & CLEANUP (Syncing on Quit)
mp.register_event("end-file", function()
    -- Only clear up_next, keep IDs for the shutdown event
    up_next_triggered = false
end)

mp.register_event("shutdown", function()
    if not scrobbled and last_active_id and last_active_type then
        if last_pos > 5 and last_pos < 90 then
            -- SYNC TO TRAKT
            mp.command_native({
                name = "subprocess",
                playback_only = false,
                args = {BRIDGE_PATH, "progress", last_active_type, last_active_id, tostring(last_pos)}
            })
        end
    end
end)

mp.add_hook("on_load", 50, function()
    local url = mp.get_property("stream-open-filename", "")
    if url:find("stremio://") == 1 then
        local stype, id = url:match("stremio://([^/]+)/(.+)")
        
        -- Update global tracking
        current_id = id
        current_type = stype
        last_active_id = id
        last_active_type = stype
        scrobbled = false
        up_next_triggered = false
        
        mp.osd_message("Resolving Stream...", 5)
        
        -- 1. Get the real stream URL
        local res = mp.command_native({
            name = "subprocess", capture_stdout = true, playback_only = false,
            args = {BRIDGE_PATH, "stream", stype, id}
        })
        
        if res and res.status == 0 and res.stdout then
            local real_url = ""
            for line in res.stdout:gmatch("[^\r\n]+") do
                if line:find("http") == 1 or line:find("magnet") == 1 then
                    real_url = line:gsub("%s+", "")
                end
            end
            
            if real_url ~= "" then
                mp.set_property("stream-open-filename", real_url)
                
                -- 2. NEW: Check for Resume Progress via the Bridge
                -- We do this as an async call so it doesn't hang the player
                mp.command_native_async({
                    name = "subprocess",
                    capture_stdout = true,
                    args = {BRIDGE_PATH, "get-progress", stype, id}
                }, function(s2, res2)
                    if res2 and res2.stdout ~= "" then
                        local progress = tonumber(res2.stdout)
                        -- Only ask if progress is between 1% and 90%
                        if progress and progress > 1 and progress < 90 then
                            local resume_menu = {
                                type = "stremio_resume",
                                title = "Resume from " .. math.floor(progress) .. "%?",
                                items = {
                                    { title = "Yes, Resume", value = "script-message stremio-do-resume " .. progress },
                                    { title = "No, Start Over", value = "ignore" }
                                }
                            }
                            mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(resume_menu))
                        end
                    end
                end)
            end
        end
    end
end)
