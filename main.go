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
		var req *http.Request
		if body != nil {
			req, _ = http.NewRequest(method, "https://api.trakt.tv/"+endpoint, bytes.NewBuffer(body))
			req.Header.Add("Content-Type", "application/json")
		} else {
			req, _ = http.NewRequest(method, "https://api.trakt.tv/"+endpoint, nil)
		}
		req.Header.Add("trakt-api-version", "2")
		req.Header.Add("trakt-api-key", config.TraktClientID)
		req.Header.Add("Authorization", "Bearer "+config.TraktToken)
		resp, err = client.Do(req)
		if err == nil && resp.StatusCode == 401 {
			data, _ := json.Marshal(map[string]string{
				"refresh_token": config.TraktRefreshToken, "client_id": config.TraktClientID,
				"client_secret": config.TraktClientSecret, "grant_type": "refresh_token",
				"redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
			})
			r, _ := http.Post("https://api.trakt.tv/oauth/token", "application/json", bytes.NewBuffer(data))
			if r != nil && r.StatusCode == 200 {
				var res struct { AccessToken, RefreshToken string `json:"access_token"` }
				json.NewDecoder(r.Body).Decode(&res)
				config.TraktToken, config.TraktRefreshToken = res.AccessToken, res.RefreshToken
				saveConfig(*config)
				continue
			}
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
	case "scrobble":
    itemType, id := os.Args[2], os.Args[3]
    var payload map[string]interface{}

    if strings.Contains(id, ":") {
        // Handle composite ID: tt12345:1:5
        parts := strings.Split(id, ":")
        showID := parts[0]
        season, _ := strconv.Atoi(parts[1])
        episode, _ := strconv.Atoi(parts[2])

        payload = map[string]interface{}{
            "episodes": []map[string]interface{}{
                {
                    "ids": map[string]string{"imdb": showID}, // Trakt can find it via Show ID + S/E
                    "season": season,
                    "number": episode,
                },
            },
        }
    } else {
        // Handle simple Movie ID
        payload = map[string]interface{}{
            itemType + "s": []map[string]interface{}{
                {"ids": map[string]string{"imdb": id}},
            },
        }
    }

    body, _ := json.Marshal(payload)
    resp, err := traktRequest("POST", "sync/history", &config, body)
    if err == nil {
        fmt.Printf("TRAKT_DEBUG: Sent %s | Status: %d\n", id, resp.StatusCode)
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
		resp, _ := traktRequest("GET", "sync/history?limit=30", &config, nil)
		if resp == nil { return }
		var items []TraktItem
		json.NewDecoder(resp.Body).Decode(&items)
		seen := make(map[string]bool)
		for _, item := range items {
			if item.Type == "movie" && item.Movie != nil && !seen[item.Movie.IDs.IMDB] {
				fmt.Printf("movie|%s|%s (%d)\n", item.Movie.IDs.IMDB, item.Movie.Title, item.Movie.Year)
				seen[item.Movie.IDs.IMDB] = true
			} else if item.Type == "episode" && item.Show != nil && !seen[item.Show.IDs.IMDB] {
				fmt.Printf("series|%s|%s [Last: S%dE%d]\n", item.Show.IDs.IMDB, item.Show.Title, item.Episode.Season, item.Episode.Number)
				seen[item.Show.IDs.IMDB] = true
			}
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
