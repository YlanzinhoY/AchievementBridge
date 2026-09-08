package gamestamp

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	Kind          = "achievement-bridge-game"
	SchemaVersion = 1
	FileName      = "achievement-bridge-game.json"
)

type Event struct {
	AppID       uint32
	Provider    string
	APIName     string
	UnlockedAt  int64
	SteamStatus string
	SteamRoute  string
}

type Achievement struct {
	APIName      string `json:"api_name"`
	UnlockedAt   int64  `json:"unlocked_at"`
	SteamStatus  string `json:"steam_status"`
	SteamRoute   string `json:"steam_route,omitempty"`
	LastVerified int64  `json:"last_verified"`
}

type Stamp struct {
	Kind               string        `json:"kind"`
	SchemaVersion      int           `json:"schema_version"`
	AppID              uint32        `json:"app_id"`
	Provider           string        `json:"provider"`
	FirstAchievementAt int64         `json:"first_achievement_at"`
	LastAchievementAt  int64         `json:"last_achievement_at"`
	UpdatedAt          int64         `json:"updated_at"`
	Achievements       []Achievement `json:"achievements"`
	Checksum           string        `json:"checksum"`
}

type Store struct {
	root string
	now  func() time.Time
	mu   sync.Mutex
}

type journalRecord struct {
	Kind       string `json:"kind"`
	AppID      uint32 `json:"app_id"`
	Provider   string `json:"provider"`
	SourceID   string `json:"source_id"`
	UnlockedAt int64  `json:"unlocked_at"`
}

func New(root string) *Store {
	return &Store{root: root, now: time.Now}
}

func DefaultRoot() string {
	if configured := strings.TrimSpace(os.Getenv("ACHIEVEMENT_BRIDGE_GAME_STATE_DIR")); configured != "" {
		return configured
	}
	root, err := os.UserCacheDir()
	if err != nil || root == "" {
		return filepath.Join(".achievement-bridge", "games")
	}
	return filepath.Join(root, "AchievementBridge", "games")
}

func DefaultJournalPath() string {
	if configured := strings.TrimSpace(os.Getenv("ACHIEVEMENT_BRIDGE_JOURNAL_PATH")); configured != "" {
		return configured
	}
	root, err := os.UserCacheDir()
	if err != nil || root == "" {
		return filepath.Join(".achievement-bridge", "journal.jsonl")
	}
	return filepath.Join(root, "AchievementBridge", "journal.jsonl")
}

func (s *Store) ImportJournal(path string) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	imported := 0
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		var record journalRecord
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			continue
		}
		if record.Kind != "event" || record.AppID == 0 || record.SourceID == "" {
			continue
		}
		if err := s.Record(Event{
			AppID:       record.AppID,
			Provider:    record.Provider,
			APIName:     record.SourceID,
			UnlockedAt:  record.UnlockedAt,
			SteamStatus: "detected",
		}); err != nil {
			return imported, err
		}
		imported++
	}
	if err := scanner.Err(); err != nil {
		return imported, fmt.Errorf("read achievement journal: %w", err)
	}
	return imported, nil
}

func (s *Store) Record(event Event) error {
	if event.AppID == 0 || strings.TrimSpace(event.Provider) == "" || strings.TrimSpace(event.APIName) == "" {
		return fmt.Errorf("game stamp requires app id, provider and achievement")
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.now().Unix()
	if event.UnlockedAt <= 0 {
		event.UnlockedAt = now
	}
	path := s.Path(event.AppID)
	stamp, err := load(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	newStamp := os.IsNotExist(err)
	if newStamp {
		stamp = Stamp{
			Kind:               Kind,
			SchemaVersion:      SchemaVersion,
			AppID:              event.AppID,
			Provider:           strings.ToLower(strings.TrimSpace(event.Provider)),
			FirstAchievementAt: event.UnlockedAt,
		}
	}
	if stamp.AppID != event.AppID {
		return fmt.Errorf("game stamp app id mismatch: expected %d, found %d", event.AppID, stamp.AppID)
	}

	changed := newStamp
	provider := strings.ToLower(strings.TrimSpace(event.Provider))
	if stamp.Provider != provider {
		stamp.Provider = provider
		changed = true
	}
	if stamp.FirstAchievementAt == 0 || event.UnlockedAt < stamp.FirstAchievementAt {
		stamp.FirstAchievementAt = event.UnlockedAt
		changed = true
	}
	if event.UnlockedAt > stamp.LastAchievementAt {
		stamp.LastAchievementAt = event.UnlockedAt
		changed = true
	}
	if upsertAchievement(&stamp, event, now) {
		changed = true
	}
	if !changed {
		return nil
	}
	stamp.UpdatedAt = now
	sort.Slice(stamp.Achievements, func(i, j int) bool {
		return stamp.Achievements[i].APIName < stamp.Achievements[j].APIName
	})
	checksum, err := calculateChecksum(stamp)
	if err != nil {
		return err
	}
	stamp.Checksum = checksum
	return write(path, stamp)
}

func (s *Store) Path(appID uint32) string {
	return filepath.Join(s.root, strconv.FormatUint(uint64(appID), 10), FileName)
}

func upsertAchievement(stamp *Stamp, event Event, verifiedAt int64) bool {
	status := strings.ToLower(strings.TrimSpace(event.SteamStatus))
	if status == "" {
		status = "detected"
	}
	for index := range stamp.Achievements {
		achievement := &stamp.Achievements[index]
		if achievement.APIName != event.APIName {
			continue
		}
		changed := false
		if achievement.UnlockedAt == 0 || event.UnlockedAt < achievement.UnlockedAt {
			achievement.UnlockedAt = event.UnlockedAt
			changed = true
		}
		if statusPriority(status) < statusPriority(achievement.SteamStatus) {
			return changed
		}
		if achievement.SteamStatus != status || achievement.SteamRoute != strings.TrimSpace(event.SteamRoute) {
			achievement.SteamStatus = status
			achievement.SteamRoute = strings.TrimSpace(event.SteamRoute)
			achievement.LastVerified = verifiedAt
			changed = true
		}
		return changed
	}
	stamp.Achievements = append(stamp.Achievements, Achievement{
		APIName:      event.APIName,
		UnlockedAt:   event.UnlockedAt,
		SteamStatus:  status,
		SteamRoute:   strings.TrimSpace(event.SteamRoute),
		LastVerified: verifiedAt,
	})
	return true
}

func statusPriority(status string) int {
	switch status {
	case "synced":
		return 3
	case "failed":
		return 2
	default:
		return 1
	}
}

func load(path string) (Stamp, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return Stamp{}, err
	}
	var stamp Stamp
	if err := json.Unmarshal(content, &stamp); err != nil {
		return Stamp{}, fmt.Errorf("decode game stamp %s: %w", path, err)
	}
	if stamp.Kind != Kind || stamp.SchemaVersion != SchemaVersion {
		return Stamp{}, fmt.Errorf("invalid game stamp marker in %s", path)
	}
	expected, err := calculateChecksum(stamp)
	if err != nil {
		return Stamp{}, err
	}
	if stamp.Checksum != expected {
		return Stamp{}, fmt.Errorf("invalid game stamp checksum in %s", path)
	}
	return stamp, nil
}

func calculateChecksum(stamp Stamp) (string, error) {
	stamp.Checksum = ""
	content, err := json.Marshal(stamp)
	if err != nil {
		return "", fmt.Errorf("encode game stamp checksum: %w", err)
	}
	digest := sha256.Sum256(content)
	return "sha256:" + hex.EncodeToString(digest[:]), nil
}

func write(path string, stamp Stamp) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create game stamp directory: %w", err)
	}
	content, err := json.MarshalIndent(stamp, "", "  ")
	if err != nil {
		return fmt.Errorf("encode game stamp: %w", err)
	}
	content = append(content, '\n')
	temporary, err := os.CreateTemp(directory, ".achievement-bridge-game-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary game stamp: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(content); err != nil {
		temporary.Close()
		return fmt.Errorf("write temporary game stamp: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("flush temporary game stamp: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return err
	}

	previous := path + ".previous"
	_ = os.Remove(previous)
	if err := os.Rename(path, previous); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("preserve previous game stamp: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		_ = os.Rename(previous, path)
		return fmt.Errorf("replace game stamp: %w", err)
	}
	_ = os.Remove(previous)
	return nil
}
