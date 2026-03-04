local mp = require 'mp'
local utils = require 'mp.utils'

-- 1. GLOBAL VARIABLES
local BRIDGE_PATH = mp.command_native({"expand-path", "~~/stremio-bridge"})
local last_query = ""
local current_id = nil
local current_type = nil
local scrobbled = false
local up_next_triggered = false
local last_active_id = nil
local last_active_type = nil
local last_pos = 0
local playlist_titles = {}
local last_season_data = ""

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

-- 5. OBSERVERS & TIMER
mp.observe_property("percent-pos", "number", function(_, val)
    if val and val > 0 then last_pos = val end
end)

mp.add_periodic_timer(10, function()
    if not current_id or not current_type then return end
    local pos = mp.get_property_number("percent-pos", 0)

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

    if current_type == "episode" and pos > 95 and not up_next_triggered then
        local count = mp.get_property_number("playlist-count", 0)
        local current_pos = mp.get_property_number("playlist-pos", 0)

        if current_pos + 1 < count then
            up_next_triggered = true
            mp.commandv("script-message-to", "uosc", "show-text", "Up Next: Starting in 10 seconds...", 10)
            mp.add_timeout(10, function()
                local current_pct = mp.get_property_number("percent-pos", 0)
                if current_pct > 90 then mp.command("playlist-next") end
            end)
        end
    end
end)

-- 6. SEARCH & EPISODES
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
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = {BRIDGE_PATH, "episodes", id}
    }, function(s, res)
        if res and res.status == 0 and res.stdout then
            last_season_data = res.stdout
            local items = {}
            for line in last_season_data:gmatch("[^\r\n]+") do
                local eid, title = line:match("([^|]+)|(.+)")
                if eid then
                    table.insert(items, { title = title, value = "script-message stremio-play-series " .. eid })
                end
            end
            mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_eps", title = "Select Episode", items = items }))
        end
    end)
end)

-- 7. PLAYLIST & UI SYNC
local function sync_uosc_playlist()
    local playlist = mp.get_property_native("playlist")
    if not playlist then return end
    local uosc_items = {}
    for i, item in ipairs(playlist) do
        local title = playlist_titles[item.filename] or item.filename
        table.insert(uosc_items, { title = title, value = i - 1, active = item.current or false, playing = item.playing or false })
    end
    mp.commandv("script-message-to", "uosc", "set-playlist", utils.format_json(uosc_items))
    local current_path = mp.get_property("path")
    if playlist_titles[current_path] then mp.set_property("file-local-options/title", playlist_titles[current_path]) end
end

mp.register_script_message("stremio-play-series", function(id)
    if not last_season_data or last_season_data == "" then return end
    mp.command("stop")
    mp.command("playlist-clear")
    playlist_titles = {} 
    local target_index = 0
    local current_count = 0
    for line in last_season_data:gmatch("[^\r\n]+") do
        local eid, title = line:match("([^|]+)|(.+)")
        if eid then
            local url = "stremio://episode/" .. eid
            playlist_titles[url] = title
            mp.commandv("loadfile", url, "append")
            if eid == id then target_index = current_count end
            current_count = current_count + 1
        end
    end
    mp.set_property_number("playlist-pos", target_index)
    mp.add_timeout(0.5, sync_uosc_playlist)
end)

mp.register_event("file-loaded", sync_uosc_playlist)
mp.register_script_message("stremio-play-movie", function(id) play("movie", id) end)

mp.register_script_message("stremio-category-select", function(stype)
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_results", title = "Search " .. stype, items = {}, search_style = "submit", on_search = "script-message stremio-search-type-callback " .. stype }))
end)

-- 8. MAIN MENU
mp.add_key_binding(nil, "stremio-menu", function()
    local items = {
        { title = "Search Movies", value = "script-message stremio-category-select movie" },
        { title = "Search Shows", value = "script-message stremio-category-select series" },
        { title = "Recently Watched", value = "script-message stremio-trakt-history" },
        { title = "--------------------------------", value = "ignore" },
        { title = "Movie Library", value = "script-message stremio-trakt-collection movies" },
        { title = "Show Library", value = "script-message stremio-trakt-collection shows" },
        { title = "Trending Movies", value = "script-message stremio-trakt-trending movies" },
        { title = "Trending Shows", value = "script-message stremio-trakt-trending shows" },
        { title = "Movie Watchlist", value = "script-message stremio-trakt-watchlist movies" },
        { title = "Show Watchlist", value = "script-message stremio-trakt-watchlist shows" }
    }

    if current_type == "episode" and current_id then
        table.insert(items, 1, { title = "⏭ Skip to Next Episode", value = "script-message stremio-manual-next" })
        table.insert(items, 2, { title = "--------------------------------", value = "ignore" })
    end

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_main_v4", title = "Stremio", items = items }))
end)

mp.register_script_message("stremio-manual-next", function()
    if not current_id or current_type ~= "episode" then return end
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

-- 9. EVENTS & HOOKS
mp.register_event("end-file", function() up_next_triggered = false end)

mp.register_event("shutdown", function()
    if not scrobbled and last_active_id and last_active_type then
        if last_pos > 5 and last_pos < 90 then
            mp.command_native({ name = "subprocess", playback_only = false, args = {BRIDGE_PATH, "progress", last_active_type, last_active_id, tostring(last_pos)} })
        end
    end
end)

mp.add_hook("on_load", 50, function()
    local url = mp.get_property("stream-open-filename", "")
    if url:find("stremio://") == 1 then
        local stype, id = url:match("stremio://([^/]+)/(.+)")
        for line in last_season_data:gmatch("[^\r\n]+") do
            local eid, title = line:match("([^|]+)|(.+)")
            if eid == id then mp.set_property("file-local-options/force-media-title", title) break end
        end
        current_id, current_type, last_active_id, last_active_type = id, stype, id, stype
        scrobbled, up_next_triggered = false, false
        mp.osd_message("Resolving Stream...", 5)
        local res = mp.command_native({ name = "subprocess", capture_stdout = true, playback_only = false, args = {BRIDGE_PATH, "stream", stype, id} })
        if res and res.status == 0 and res.stdout then
            for line in res.stdout:gmatch("[^\r\n]+") do
                if line:find("http") == 1 or line:find("magnet") == 1 then
                    mp.set_property("stream-open-filename", line:gsub("%s+", ""))
                    mp.command_native_async({ name = "subprocess", capture_stdout = true, args = {BRIDGE_PATH, "get-progress", stype, id} }, function(s2, res2)
                        if res2 and res2.stdout ~= "" then
                            local progress = tonumber(res2.stdout)
                            if progress and progress > 1 and progress < 90 then
                                mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({ type = "stremio_resume", title = "Resume from " .. math.floor(progress) .. "%?", items = {{ title = "Yes, Resume", value = "script-message stremio-do-resume " .. progress }, { title = "No, Start Over", value = "ignore" }} }))
                            end
                        end
                    end)
                end
            end
        end
    end
end)
