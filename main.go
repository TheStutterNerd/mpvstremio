package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Config struct {
	RDEnabled bool
	RDKey     string
}

type Stream struct {
	URL      string `json:"url"`
	InfoHash string `json:"infoHash"`
}

type StreamResponse struct {
	Streams []Stream `json:"streams"`
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

type CatalogResponse struct {
	Metas []Meta `json:"metas"`
}

type MetaResponse struct {
	Meta Meta `json:"meta"`
}

type ScoredMeta struct {
	Meta  Meta
	Score int
}

func loadConfig() Config {
	conf := Config{RDEnabled: false, RDKey: ""}
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
			if k == "REAL_DEBRID_ENABLED" {
				conf.RDEnabled = strings.ToLower(v) == "true"
			} else if k == "REAL_DEBRID_KEY" {
				conf.RDKey = v
			}
		}
	}
	return conf
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

	sort.Slice(scoredList, func(i, j int) bool {
		return scoredList[i].Score > scoredList[j].Score
	})

	for _, sm := range scoredList {
		m := sm.Meta
		yearInfo := ""
		if m.Year != "" { yearInfo = " (" + m.Year + ")" }
		fmt.Printf("%s|%s|%s%s\n", m.Type, m.ID, m.Name, yearInfo)
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
	if len(os.Args) < 3 { return }
	cmd := os.Args[1]
	switch cmd {
	case "search":
		if len(os.Args) < 4 { return }
		search(os.Args[2], os.Args[3])
	case "episodes": getEpisodes(os.Args[2])
	case "stream": getStream(os.Args[2], os.Args[3])
	}
}
