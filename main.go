package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"strconv"
)

type Config struct {
	RDEnabled bool
	RDKey, TraktToken, TraktRefreshToken, TraktClientID, TraktClientSecret string
}

type StreamResponse struct { Streams []struct { URL, InfoHash string } }
type Meta struct { ID, Type, Name, Year string; Videos []Video }
type Video struct { ID string; Season, Episode int; Name string }
type CatalogResponse struct { Metas []Meta }
type MetaResponse struct { Meta Meta }
type ScoredMeta struct { Meta Meta; Score int }

type TraktItem struct {
	Type  string `json:"type"`
	Movie *struct { Title string; Year int; IDs struct{ IMDB string } `json:"ids"` } `json:"movie"`
	Show  *struct { Title string; IDs struct{ IMDB string } `json:"ids"` } `json:"show"`
	Episode *struct { Title string; Season, Number int } `json:"episode"`
}

func loadConfig() Config {
	conf := Config{}
	exePath, _ := os.Executable()
	confPath := filepath.Join(filepath.Dir(exePath), "mpvstremio.conf")
	file, _ := os.Open(confPath)
	if file != nil {
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			parts := strings.SplitN(scanner.Text(), "=", 2)
			if len(parts) == 2 {
				k, v := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
				switch k {
				case "REAL_DEBRID_ENABLED": conf.RDEnabled = strings.ToLower(v) == "true"
				case "REAL_DEBRID_KEY": conf.RDKey = v
				case "TRAKT_ACCESS_TOKEN": conf.TraktToken = v
				case "TRAKT_REFRESH_TOKEN": conf.TraktRefreshToken = v
				case "TRAKT_CLIENT_ID": conf.TraktClientID = v
				case "TRAKT_CLIENT_SECRET": conf.TraktClientSecret = v
				}
			}
		}
		file.Close()
	}
	return conf
}

func saveConfig(conf Config) {
	exePath, _ := os.Executable()
	confPath := filepath.Join(filepath.Dir(exePath), "mpvstremio.conf")
	content := fmt.Sprintf("REAL_DEBRID_ENABLED=%v\nREAL_DEBRID_KEY=%s\nTRAKT_ACCESS_TOKEN=%s\nTRAKT_REFRESH_TOKEN=%s\nTRAKT_CLIENT_ID=%s\nTRAKT_CLIENT_SECRET=%s\n",
		conf.RDEnabled, conf.RDKey, conf.TraktToken, conf.TraktRefreshToken, conf.TraktClientID, conf.TraktClientSecret)
	os.WriteFile(confPath, []byte(content), 0644)
}

func traktRequest(method, endpoint string, config *Config, body []byte) (*http.Response, error) {
    client := &http.Client{Timeout: 20 * time.Second}
    var resp *http.Response
    var err error

    for i := 0; i < 3; i++ {
        // Ensure no double slashes and correct base URL
        u := "https://api.trakt.tv/" + strings.TrimPrefix(endpoint, "/")
        
        var req *http.Request
        if body != nil {
            req, _ = http.NewRequest(method, u, bytes.NewBuffer(body))
        } else {
            req, _ = http.NewRequest(method, u, nil)
        }

        // 412-Killer Headers: Trakt requires BOTH of these for many endpoints
        req.Header.Set("Content-Type", "application/json")
        req.Header.Set("Accept", "application/json")
        
        req.Header.Set("trakt-api-version", "2")
        req.Header.Set("trakt-api-key", config.TraktClientID)
        req.Header.Set("Authorization", "Bearer "+config.TraktToken)

        resp, err = client.Do(req)

        if err == nil && resp.StatusCode == 401 {
            // ... (Your existing refresh logic)
            // IMPORTANT: Close the old body before retrying
            if resp.Body != nil { resp.Body.Close() }
            
            // [Token refresh code remains the same as your previous version]
            // ...
            continue
        }

        if err == nil { return resp, nil }
        time.Sleep(500 * time.Millisecond)
    }
    return resp, err
}

func main() {
	if len(os.Args) < 2 { return }
	cmd, config := os.Args[1], loadConfig()

	switch cmd {
	case "next-episode":
    idParts := strings.Split(strings.TrimSpace(os.Args[2]), ":")
    if len(idParts) < 3 { return }
    
    imdbID := idParts[0]
    currS, _ := strconv.Atoi(idParts[1])
    currE, _ := strconv.Atoi(idParts[2])

    // Get the episode count for the CURRENT season
    endpoint := fmt.Sprintf("shows/%s/seasons/%d", imdbID, currS)
    resp, err := traktRequest("GET", endpoint, &config, nil)
    
    if err == nil && resp.StatusCode == 200 {
        var seasonData []struct {
            Number int `json:"number"`
        }
        json.NewDecoder(resp.Body).Decode(&seasonData)
        resp.Body.Close()

        // seasonData is an array of all episodes in the current season.
        // If our current episode is less than the HIGHEST episode number in this season:
        lastEpisodeInSeason := 0
        for _, ep := range seasonData {
            if ep.Number > lastEpisodeInSeason {
                lastEpisodeInSeason = ep.Number
            }
        }

        if currE < lastEpisodeInSeason {
            // Stay in current season, go to next episode
            fmt.Printf("episode|%s:%d:%d", imdbID, currS, currE+1)
        } else {
            // We are at the last episode of the season, go to next season
            fmt.Printf("episode|%s:%d:%d", imdbID, currS+1, 1)
        }
    } else {
        // Fallback: If API fails, assume there's another episode in this season
        fmt.Printf("episode|%s:%d:%d", imdbID, currS, currE+1)
    }

	case "get-progress":
        if len(os.Args) < 4 { return }
        _, id := os.Args[2], os.Args[3]
        resp, err := traktRequest("GET", "sync/playback", &config, nil)
        if err == nil && resp != nil {
            var results []map[string]interface{}
            json.NewDecoder(resp.Body).Decode(&results)
            resp.Body.Close()
            for _, item := range results {
                var itemID string
                // SAFE CHECK: Ensure type exists
                pType, _ := item["type"].(string)
                
                if pType == "episode" {
                    // SAFE CHECK: Nested show and episode objects
                    show, ok1 := item["show"].(map[string]interface{})
                    ep, ok2 := item["episode"].(map[string]interface{})
                    if ok1 && ok2 {
                        ids, _ := show["ids"].(map[string]interface{})
                        imdb, _ := ids["imdb"].(string)
                        if imdb != "" {
                            itemID = fmt.Sprintf("%s:%v:%v", imdb, ep["season"], ep["number"])
                        }
                    }
                } else if pType == "movie" {
                    movie, ok := item["movie"].(map[string]interface{})
                    if ok {
                        ids, _ := movie["ids"].(map[string]interface{})
                        imdb, _ := ids["imdb"].(string)
                        itemID = imdb
                    }
                }

                if itemID != "" && itemID == id {
                    fmt.Printf("%v", item["progress"])
                    return
                }
            }
        }

    case "check-progress":
        resp, err := traktRequest("GET", "sync/playback", &config, nil)
        if err == nil && resp != nil {
            var results []map[string]interface{}
            json.NewDecoder(resp.Body).Decode(&results)
            resp.Body.Close()
            
            fmt.Println("--- Active Trakt Bookmarks ---")
            for _, item := range results {
                progress, _ := item["progress"].(float64)
                pType, _ := item["type"].(string)
                
                var title string
                if pType == "episode" {
                    show, ok1 := item["show"].(map[string]interface{})
                    ep, ok2 := item["episode"].(map[string]interface{})
                    if ok1 && ok2 {
                        title = fmt.Sprintf("%v (S%vE%v)", show["title"], ep["season"], ep["number"])
                    }
                } else if pType == "movie" {
                    movie, ok := item["movie"].(map[string]interface{})
                    if ok {
                        title = fmt.Sprintf("%v", movie["title"])
                    }
                }
                
                if title != "" {
                    fmt.Printf("[%s] %s: %.1f%%\n", pType, title, progress)
                }
            }
        }	

	case "progress":
    // args: [2]=type, [3]=id, [4]=percentage
    _, id, percentStr := os.Args[2], os.Args[3], os.Args[4]
    percent, _ := strconv.ParseFloat(percentStr, 64)

    var payload map[string]interface{}
    if strings.Contains(id, ":") {
        parts := strings.Split(id, ":")
        showID := parts[0]
        s, _ := strconv.Atoi(parts[1])
        e, _ := strconv.Atoi(parts[2])

        payload = map[string]interface{}{
            "progress": percent,
            "show":     map[string]interface{}{"ids": map[string]string{"imdb": showID}},
            "episode":  map[string]interface{}{"season": s, "number": e},
        }
    } else {
        payload = map[string]interface{}{
            "progress": percent,
            "movie":    map[string]interface{}{"ids": map[string]string{"imdb": id}},
        }
    }

    body, _ := json.Marshal(payload)
    // We use the /scrobble/pause endpoint to save the resume point
    resp, err := traktRequest("POST", "scrobble/pause", &config, body)
    if err == nil && resp.StatusCode == 201 {
        fmt.Printf("TRAKT: Progress saved at %.0f%%\n", percent)
    }

	case "scrobble":
    _, id := os.Args[2], os.Args[3]
    var payload map[string]interface{}

    if strings.Contains(id, ":") {
        parts := strings.Split(id, ":")
        showIMDB := parts[0]
        s, _ := strconv.Atoi(parts[1])
        e, _ := strconv.Atoi(parts[2])

        // THE FIX: Nest the episode inside a show object
        payload = map[string]interface{}{
            "shows": []map[string]interface{}{
                {
                    "ids": map[string]string{"imdb": showIMDB},
                    "seasons": []map[string]interface{}{
                        {
                            "number": s,
                            "episodes": []map[string]interface{}{
                                {"number": e},
                            },
                        },
                    },
                },
            },
        }
    } else {
        // Movies stay the same
        payload = map[string]interface{}{
            "movies": []map[string]interface{}{
                {"ids": map[string]string{"imdb": id}},
            },
        }
    }

    body, _ := json.Marshal(payload)

		resp, err := traktRequest("POST", "sync/history", &config, body)
		if err == nil {
    		// READ THE BODY TO SEE WHAT WAS ACTUALLY ADDED
    		var result map[string]interface{}
    		json.NewDecoder(resp.Body).Decode(&result)
    		
    		added := result["added"].(map[string]interface{})
    		fmt.Printf("TRAKT CONFIRMATION: Added %v episodes, %v movies\n", added["episodes"], added["movies"])
    		
    		if fmt.Sprintf("%v", added["episodes"]) == "0" && fmt.Sprintf("%v", added["movies"]) == "0" {
        		fmt.Println("WARNING: Trakt accepted the request but ADDED ZERO items. Check your IDs.")
    		}
		}

  	case "collection":
    	// args: [2] = movies or shows
    	endpoint := "sync/collection/" + os.Args[2]
    	resp, _ := traktRequest("GET", endpoint, &config, nil)
    	if resp == nil { return }
    	var items []TraktItem
    	json.NewDecoder(resp.Body).Decode(&items)
    	for _, item := range items {
        	if item.Movie != nil { 
            	fmt.Printf("movie|%s|%s (%d)\n", item.Movie.IDs.IMDB, item.Movie.Title, item.Movie.Year)
        	} else if item.Show != nil { 
            	fmt.Printf("series|%s|%s\n", item.Show.IDs.IMDB, item.Show.Title) 
        	}
    	}

	
	case "history":
    resp, _ := traktRequest("GET", "sync/history?limit=100", &config, nil)
    if resp == nil { return }
    
    var items []TraktItem
    json.NewDecoder(resp.Body).Decode(&items)
    
    seen := make(map[string]bool)
    count := 0
    for _, item := range items {
        var id, title string
        
        if item.Type == "movie" && item.Movie != nil {
            id = item.Movie.IDs.IMDB
            title = fmt.Sprintf("movie|%s|%s (%d)", id, item.Movie.Title, item.Movie.Year)
        } else if item.Type == "episode" && item.Show != nil {
            id = item.Show.IDs.IMDB
            title = fmt.Sprintf("series|%s|%s [Last: S%dE%d]", id, item.Show.Title, item.Episode.Season, item.Episode.Number)
        }

        if id != "" && !seen[id] {
            fmt.Println(title)
            seen[id] = true
            count++
        }
        
        // Stop after showing 15 unique shows to keep the menu snappy
        if count >= 15 { break }
    }
	case "watchlist", "trending":
		endpoint := "sync/watchlist/" + os.Args[2]
		if cmd == "trending" { endpoint = os.Args[2] + "/trending?limit=20" }
		resp, _ := traktRequest("GET", endpoint, &config, nil)
		if resp == nil { return }
		var items []TraktItem
		json.NewDecoder(resp.Body).Decode(&items)
		for _, item := range items {
			if item.Movie != nil { fmt.Printf("movie|%s|%s (%d)\n", item.Movie.IDs.IMDB, item.Movie.Title, item.Movie.Year)
			} else if item.Show != nil { fmt.Printf("series|%s|%s\n", item.Show.IDs.IMDB, item.Show.Title) }
		}
	case "search":
		stype, query := os.Args[2], os.Args[3]
		u := fmt.Sprintf("https://v3-cinemeta.strem.io/catalog/%s/top/search=%s.json", stype, url.PathEscape(query))
		r, _ := http.Get(u)
		if r == nil { return }
		var res CatalogResponse
		json.NewDecoder(r.Body).Decode(&res)
		lowerQuery := strings.ToLower(strings.TrimSpace(query))
		scored := make([]ScoredMeta, 0)
		for _, m := range res.Metas {
			name, score := strings.ToLower(m.Name), 0
			if name == lowerQuery { score += 2000 }
			if strings.HasPrefix(name, lowerQuery) { score += 1000 }
			if strings.Contains(name, lowerQuery) { score += 500 }
			scored = append(scored, ScoredMeta{m, score - len(name)})
		}
		sort.Slice(scored, func(i, j int) bool { return scored[i].Score > scored[j].Score })
		for _, sm := range scored {
			year := ""
			if sm.Meta.Year != "" { year = " (" + sm.Meta.Year + ")" }
			fmt.Printf("%s|%s|%s%s\n", sm.Meta.Type, sm.Meta.ID, sm.Meta.Name, year)
		}
	case "episodes":
		u := "https://v3-cinemeta.strem.io/meta/series/" + os.Args[2] + ".json"
		r, _ := http.Get(u)
		if r == nil { return }
		var res MetaResponse
		json.NewDecoder(r.Body).Decode(&res)
		for _, v := range res.Meta.Videos {
			if v.Season > 0 { 
				id, name := v.ID, v.Name
				if id == "" { id = fmt.Sprintf("%s:%d:%d", os.Args[2], v.Season, v.Episode) }
				if name == "" { name = fmt.Sprintf("Episode %d", v.Episode) }
				fmt.Printf("%s|S%dE%d: %s\n", id, v.Season, v.Episode, name) 
			}
		}
	case "stream":
		id, finalType := os.Args[3], os.Args[2]
		if strings.Contains(id, ":") { finalType = "series" }
		u := fmt.Sprintf("https://torrentio.strem.fun/stream/%s/%s.json", finalType, id)
		if config.RDEnabled && config.RDKey != "" { u = fmt.Sprintf("https://torrentio.strem.fun/realdebrid=%s/stream/%s/%s.json", config.RDKey, finalType, id) }
		client := &http.Client{}
		req, _ := http.NewRequest("GET", u, nil)
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, _ := client.Do(req)
		if resp == nil { return }
		var res StreamResponse
		json.NewDecoder(resp.Body).Decode(&res)
		if len(res.Streams) > 0 {
			if res.Streams[0].URL != "" { fmt.Println(res.Streams[0].URL) } else { fmt.Println("magnet:?xt=urn:btih:" + res.Streams[0].InfoHash) }
		}
	}
}
