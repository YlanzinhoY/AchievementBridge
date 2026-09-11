package monitor

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/providers"
)

type journalRecord struct {
	Kind       string `json:"kind"`
	AppID      uint32 `json:"app_id"`
	Provider   string `json:"provider"`
	SourceID   string `json:"source_id,omitempty"`
	UnlockedAt int64  `json:"unlocked_at,omitempty"`
	DetectedAt int64  `json:"detected_at,omitempty"`
	Recovered  bool   `json:"recovered,omitempty"`
}

type Journal struct {
	path       string
	mu         sync.Mutex
	seenGames  map[string]struct{}
	seenEvents map[string]struct{}
}

func OpenJournal(path string) (*Journal, error) {
	journal := &Journal{
		path:       path,
		seenGames:  make(map[string]struct{}),
		seenEvents: make(map[string]struct{}),
	}
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		return journal, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	buffer := make([]byte, 64*1024)
	scanner.Buffer(buffer, 32*1024*1024)
	for scanner.Scan() {
		var record journalRecord
		if json.Unmarshal(scanner.Bytes(), &record) != nil || record.AppID == 0 {
			continue
		}
		if record.Provider == "" {
			record.Provider = "gse"
		}
		if record.Kind == "game" || record.Kind == "event" {
			journal.seenGames[gameKey(record.Provider, record.AppID)] = struct{}{}
		}
		if record.SourceID != "" {
			journal.seenEvents[eventKey(record.Provider, record.AppID, record.SourceID)] = struct{}{}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return journal, nil
}

func (j *Journal) HasGame(provider string, appID uint32) bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	_, found := j.seenGames[gameKey(provider, appID)]
	return found
}

func (j *Journal) HasEvent(provider string, appID uint32, sourceID string) bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	_, found := j.seenEvents[eventKey(provider, appID, sourceID)]
	return found
}

func (j *Journal) MarkGame(provider string, appID uint32) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	key := gameKey(provider, appID)
	if _, exists := j.seenGames[key]; exists {
		return nil
	}
	if err := j.appendLocked(journalRecord{Kind: "game", AppID: appID, Provider: provider}); err != nil {
		return err
	}
	j.seenGames[key] = struct{}{}
	return nil
}

func (j *Journal) Baseline(provider string, appID uint32, state providers.Snapshot) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	for sourceID, achievement := range state {
		if !achievement.Unlocked {
			continue
		}
		key := eventKey(provider, appID, sourceID)
		if _, exists := j.seenEvents[key]; exists {
			continue
		}
		if err := j.appendLocked(journalRecord{
			Kind:       "baseline",
			AppID:      appID,
			Provider:   provider,
			SourceID:   sourceID,
			UnlockedAt: achievement.Timestamp,
		}); err != nil {
			return err
		}
		j.seenEvents[key] = struct{}{}
	}
	return nil
}

func (j *Journal) Record(event providers.Event) (bool, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	key := eventKey(event.Provider, event.AppID, event.Achievement)
	if _, exists := j.seenEvents[key]; exists {
		return false, nil
	}
	detectedAt := event.DetectedAt.Unix()
	if event.DetectedAt.IsZero() {
		detectedAt = time.Now().Unix()
	}
	if err := j.appendLocked(journalRecord{
		Kind:       "event",
		AppID:      event.AppID,
		Provider:   event.Provider,
		SourceID:   event.Achievement,
		UnlockedAt: event.Timestamp,
		DetectedAt: detectedAt,
		Recovered:  event.Recovered,
	}); err != nil {
		return false, err
	}
	j.seenGames[gameKey(event.Provider, event.AppID)] = struct{}{}
	j.seenEvents[key] = struct{}{}
	return true, nil
}

func (j *Journal) appendLocked(record journalRecord) error {
	if err := os.MkdirAll(filepath.Dir(j.path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(j.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	return json.NewEncoder(file).Encode(record)
}

func gameKey(provider string, appID uint32) string {
	return fmt.Sprintf("%s:%d", provider, appID)
}

func eventKey(provider string, appID uint32, sourceID string) string {
	return fmt.Sprintf("%s:%d:%s", provider, appID, sourceID)
}
