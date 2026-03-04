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
)

type Config struct {
	RDEnabled         bool
	RDKey             string
	TraktToken        string
	TraktRefreshToken string
	TraktClientID     string
	TraktClientSecret string
}

type StreamResponse struct {
	Streams []struct {
		URL      string `json:"url"`
		InfoHash string `json:"infoHash"`
	} `json:"streams"`
}

type Video struct {
	ID      string `json:"id"`
	Season  int    `json:"season"`
	Episode int    `json:"number"`
	Name    string `json:"name"`
}

type Meta struct {
	ID     string  `json:"id"`
	Type   string  `json:"type"`
	Name   string  `json:"name"`
	Year   string  `json:"year"`
	Videos []Video `json:"videos"`
}

type CatalogResponse struct{ Metas []Meta `json:"metas"` }
type MetaResponse    struct{ Meta Meta `json:"meta"` }
type ScoredMeta      struct {
	Meta  Meta
	Score int
}

type TraktItem struct {
	Type  string `json:"type"`
	Movie *struct {
		Title string `json:"title"`
		Year  int    `json:"year"`
		IDs   struct{ IMDB string `json:"imdb"` } `json:"ids"`
	} `json:"movie"`
	Show *struct {
		Title string `json:"title"`
		IDs   struct{ IMDB string `json:"imdb"` } `json:"ids"`
	} `json:"show"`
	Episode *struct {
		Title  string `json:"title"`
		Season int    `json:"season"`
		Number int    `json:"number"`
	} `json:"episode"`
}

func loadConfig() Config {
	conf := Config{}
	exePath, _ := os.Executable()
	confPath := filepath.Join(filepath.Dir(exePath), "mpvstremio.conf")
	file, err := os.Open(confPath)
	if err != nil { return conf }
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), "=", 2)
		if len(parts) == 2 {
			k, v := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
			switch k {
			case "REAL_DEBRID_ENABLED": conf.RDEnabled = strings.ToLower(v) == "true"
			case "REAL_DEBRID_KEY":     conf.RDKey = v
			case "TRAKT_ACCESS_TOKEN":  conf.TraktToken = v
			case "TRAKT_REFRESH_TOKEN": conf.TraktRefreshToken = v
			case "TRAKT_CLIENT_ID":     conf.TraktClientID = v
			case "TRAKT_CLIENT_SECRET": conf.TraktClientSecret = v
			}
		}
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

func refreshTraktToken(conf *Config) bool {
	data := map[string]string{
		"refresh_token": conf.TraktRefreshToken,
		"client_id":     conf.TraktClientID,
		"client_secret": conf.TraktClientSecret,
		"grant_type":    "refresh_token",
		"redirect_uri":  "urn:ietf:wg:oauth:2.0:oob",
	}
	body, _ := json.Marshal(data)
	resp, err := http.Post("https://api.trakt.tv/oauth/token", "application/json", bytes.NewBuffer(body))
	if err != nil || resp.StatusCode != 200 { return false }
	defer resp.Body.Close()

	var res struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	json.NewDecoder(resp.Body).Decode(&res)
	conf.TraktToken = res.AccessToken
	conf.TraktRefreshToken = res.RefreshToken
	saveConfig(*conf)
	return true
}

func traktRequest(method, endpoint string, config *Config) (*http.Response, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	req, _ := http.NewRequest(method, "https://api.trakt.tv/"+endpoint, nil)
	req.Header.Add("trakt-api-version", "2")
	req.Header.Add("trakt-api-key", config.TraktClientID)
	req.Header.Add("Authorization", "Bearer "+config.TraktToken)
	
	resp, err := client.Do(req)
	if err == nil && resp.StatusCode == 401 {
		if refreshTraktToken(config) {
			return traktRequest(method, endpoint, config) // Recursive retry
		}
	}
	return resp, err
}

func getTraktWatchlist(itemType string) {
	config := loadConfig()
	resp, err := traktRequest("GET", "sync/watchlist/"+itemType, &config)
	if err != nil || resp == nil || resp.StatusCode != 200 { return }
	defer resp.Body.Close()

	var items []TraktItem
	json.NewDecoder(resp.Body).Decode(&items)
	for _, item := range items {
		if itemType == "movies" && item.Movie != nil {
			fmt.Printf("movie|%s|%s (%d)\n", item.Movie.IDs.IMDB, item.Movie.Title, item.Movie.Year)
		} else if itemType == "shows" && item.Show != nil {
			fmt.Printf("series|%s|%s\n", item.Show.IDs.IMDB, item.Show.Title)
		}
	}
}

func getTraktHistory() {
	config := loadConfig()
	resp, err := traktRequest("GET", "sync/history?limit=30", &config)
	if err != nil || resp == nil || resp.StatusCode != 200 { return }
	defer resp.Body.Close()

	var items []TraktItem
	json.NewDecoder(resp.Body).Decode(&items)
	// Track unique IDs to avoid duplicates if someone watched multiple eps of same show
	seen := make(map[string]bool)

	for _, item := range items {
		if item.Type == "movie" && item.Movie != nil {
			if seen[item.Movie.IDs.IMDB] { continue }
			fmt.Printf("movie|%s|%s (%d)\n", item.Movie.IDs.IMDB, item.Movie.Title, item.Movie.Year)
			seen[item.Movie.IDs.IMDB] = true
		} else if item.Type == "episode" && item.Show != nil {
			if seen[item.Show.IDs.IMDB] { continue }
			fmt.Printf("series|%s|%s [Last: S%dE%d]\n", item.Show.IDs.IMDB, item.Show.Title, item.Episode.Season, item.Episode.Number)
			seen[item.Show.IDs.IMDB] = true
		}
	}
}

func search(stype, query string) {
	lowerQuery := strings.ToLower(strings.TrimSpace(query))
	apiURL := fmt.Sprintf("https://v3-cinemeta.strem.io/catalog/%s/top/search=%s.json", stype, url.PathEscape(query))
	resp, err := http.Get(apiURL)
	if err != nil || resp == nil { return }
	defer resp.Body.Close()

	var res CatalogResponse
	json.NewDecoder(resp.Body).Decode(&res)

	scoredList := make([]ScoredMeta, 0)
	for _, m := range res.Metas {
		name := strings.ToLower(m.Name)
		score := 0
		if name == lowerQuery { score += 2000 }
		if strings.HasPrefix(name, lowerQuery) { score += 1000 }
		if strings.Contains(name, lowerQuery) { score += 500 }
		score -= len(name)
		scoredList = append(scoredList, ScoredMeta{m, score})
	}

	sort.Slice(scoredList, func(i, j int) bool { return scoredList[i].Score > scoredList[j].Score })

	for _, sm := range scoredList {
		m := sm.Meta
		year := ""
		if m.Year != "" { year = " (" + m.Year + ")" }
		fmt.Printf("%s|%s|%s%s\n", m.Type, m.ID, m.Name, year)
	}
}

func getEpisodes(id string) {
	apiURL := "https://v3-cinemeta.strem.io/meta/series/" + id + ".json"
	resp, _ := http.Get(apiURL)
	if resp == nil { return }
	defer resp.Body.Close()
	var res MetaResponse
	json.NewDecoder(resp.Body).Decode(&res)
	for _, v := range res.Meta.Videos {
		if v.Season == 0 { continue }
		vID := v.ID
		if vID == "" { vID = fmt.Sprintf("%s:%d:%d", id, v.Season, v.Episode) }
		title := v.Name
		if title == "" { title = fmt.Sprintf("Episode %d", v.Episode) }
		fmt.Printf("%s|S%dE%d: %s\n", vID, v.Season, v.Episode, title)
	}
}

func getStream(contentType, id string) {
	config := loadConfig()
	finalType := contentType
	if strings.Contains(id, ":") { finalType = "series" }
	apiURL := fmt.Sprintf("https://torrentio.strem.fun/stream/%s/%s.json", finalType, id)
	if config.RDEnabled && config.RDKey != "" {
		apiURL = fmt.Sprintf("https://torrentio.strem.fun/realdebrid=%s/stream/%s/%s.json", config.RDKey, finalType, id)
	}
	client := &http.Client{}
	req, _ := http.NewRequest("GET", apiURL, nil)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, _ := client.Do(req)
	if resp == nil { return }
	defer resp.Body.Close()
	var res StreamResponse
	json.NewDecoder(resp.Body).Decode(&res)
	if len(res.Streams) > 0 {
		s := res.Streams[0]
		if s.URL != "" { fmt.Println(s.URL) } else { fmt.Printf("magnet:?xt=urn:btih:%s\n", s.InfoHash) }
	}
}

func main() {
	if len(os.Args) < 2 { return }
	cmd := os.Args[1]
	switch cmd {
	case "search":
		if len(os.Args) < 4 { return }
		search(os.Args[2], os.Args[3])
	case "watchlist":
		if len(os.Args) < 3 { return }
		getTraktWatchlist(os.Args[2])
	case "history":
		getTraktHistory()
	case "episodes": getEpisodes(os.Args[2])
	case "stream": getStream(os.Args[2], os.Args[3])
	}
}
