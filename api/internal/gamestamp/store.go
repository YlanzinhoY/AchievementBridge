package gamestamp

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
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
	AppID            uint32
	Provider         string
	SourceID         string
	CanonicalAPIName string
	UnlockedAt       int64
	SteamStatus      string
	SteamRoute       string
}

type Achievement struct {
	Provider     string `json:"provider"`
	SourceID     string `json:"source_id"`
	APIName      string `json:"api_name,omitempty"`
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

type supportManifest struct {
	SchemaVersion     int     `json:"schema_version"`
	SteamAppID        uint32  `json:"steam_app_id"`
	Provider          string  `json:"provider"`
	ProviderProductID *uint32 `json:"provider_product_id"`
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

func DefaultSupportRoot() string {
	if configured := strings.TrimSpace(os.Getenv("ACHIEVEMENT_BRIDGE_SUPPORT_DIR")); configured != "" {
		return configured
	}
	root, err := os.UserCacheDir()
	if err != nil || root == "" {
		return filepath.Join(".achievement-bridge", "support")
	}
	return filepath.Join(root, "AchievementBridge", "support")
}

func (s *Store) ImportJournal(path string, supportRoot string) (int, error) {
	productIDs, err := loadProductIDs(supportRoot)
	if err != nil {
		return 0, err
	}
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	imported := 0
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		record := journalRecord{Provider: "gse"}
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			continue
		}
		if record.Kind != "event" || record.AppID == 0 || record.SourceID == "" {
			continue
		}
		record.Provider = strings.ToLower(strings.TrimSpace(record.Provider))
		if !supportedProvider(record.Provider) {
			continue
		}
		appID := record.AppID
		if strings.EqualFold(record.Provider, "uplay_r2") {
			resolved, found := productIDs[providerProductKey(record.Provider, record.AppID)]
			if !found || resolved == 0 {
				continue
			}
			appID = resolved
		}
		if err := s.Record(Event{
			AppID:       appID,
			Provider:    record.Provider,
			SourceID:    record.SourceID,
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

func loadProductIDs(supportRoot string) (map[string]uint32, error) {
	result := make(map[string]uint32)
	paths, err := filepath.Glob(filepath.Join(supportRoot, "games", "*", "support.json"))
	if err != nil {
		return nil, fmt.Errorf("find support manifests: %w", err)
	}
	for _, path := range paths {
		content, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var manifest supportManifest
		if json.Unmarshal(content, &manifest) != nil || manifest.SchemaVersion != 1 || manifest.SteamAppID == 0 || manifest.ProviderProductID == nil || *manifest.ProviderProductID == 0 {
			continue
		}
		if filepath.Base(filepath.Dir(path)) != strconv.FormatUint(uint64(manifest.SteamAppID), 10) {
			continue
		}
		key := providerProductKey(manifest.Provider, *manifest.ProviderProductID)
		if existing, found := result[key]; found && existing != manifest.SteamAppID {
			result[key] = 0 // Ambiguous ownership must not select a game arbitrarily.
		} else {
			result[key] = manifest.SteamAppID
		}
	}
	return result, nil
}

func providerProductKey(provider string, productID uint32) string {
	return strings.ToLower(strings.TrimSpace(provider)) + ":" + strconv.FormatUint(uint64(productID), 10)
}

func (s *Store) Record(event Event) error {
	event.Provider = strings.ToLower(strings.TrimSpace(event.Provider))
	event.SourceID = strings.TrimSpace(event.SourceID)
	event.SteamStatus = strings.ToLower(strings.TrimSpace(event.SteamStatus))
	if event.SteamStatus == "" {
		event.SteamStatus = "detected"
	}
	if event.AppID == 0 || !supportedProvider(event.Provider) || event.SourceID == "" {
		return fmt.Errorf("game stamp requires app id, provider and achievement")
	}
	if event.SteamStatus != "detected" && event.SteamStatus != "synced" && event.SteamStatus != "failed" {
		return fmt.Errorf("invalid Steam status for game stamp")
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.now().Unix()
	if event.UnlockedAt < 0 {
		event.UnlockedAt = 0
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
	if upsertAchievement(&stamp, event, now) {
		changed = true
	}
	if !changed {
		return nil
	}
	stamp.UpdatedAt = now
	stamp.FirstAchievementAt, stamp.LastAchievementAt = 0, 0
	for _, achievement := range stamp.Achievements {
		if achievement.UnlockedAt > 0 && (stamp.FirstAchievementAt == 0 || achievement.UnlockedAt < stamp.FirstAchievementAt) {
			stamp.FirstAchievementAt = achievement.UnlockedAt
		}
		if achievement.UnlockedAt > stamp.LastAchievementAt {
			stamp.LastAchievementAt = achievement.UnlockedAt
		}
	}
	sort.Slice(stamp.Achievements, func(i, j int) bool {
		if stamp.Achievements[i].Provider != stamp.Achievements[j].Provider {
			return stamp.Achievements[i].Provider < stamp.Achievements[j].Provider
		}
		return stamp.Achievements[i].SourceID < stamp.Achievements[j].SourceID
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
		if achievement.SourceID != event.SourceID || achievement.Provider != event.Provider {
			continue
		}
		changed := false
		if event.UnlockedAt > 0 && (achievement.UnlockedAt == 0 || event.UnlockedAt < achievement.UnlockedAt) {
			achievement.UnlockedAt = event.UnlockedAt
			changed = true
		}
		if statusPriority(status) < statusPriority(achievement.SteamStatus) {
			return changed
		}
		canonical := strings.TrimSpace(event.CanonicalAPIName)
		if achievement.SteamStatus != status || achievement.SteamRoute != strings.TrimSpace(event.SteamRoute) || (canonical != "" && achievement.APIName != canonical) {
			achievement.SteamStatus = status
			achievement.SteamRoute = strings.TrimSpace(event.SteamRoute)
			if canonical != "" {
				achievement.APIName = canonical
			}
			achievement.LastVerified = verifiedAt
			changed = true
		}
		return changed
	}
	stamp.Achievements = append(stamp.Achievements, Achievement{
		Provider:     event.Provider,
		SourceID:     event.SourceID,
		APIName:      strings.TrimSpace(event.CanonicalAPIName),
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

func supportedProvider(provider string) bool {
	switch provider {
	case "gse", "rune", "rockstar", "uplay_r2", "steam":
		return true
	default:
		return false
	}
}

// Load validates one stamp; callers can use it when discovering portable state.
func Load(path string) (Stamp, error) { return load(path) }

func load(path string) (Stamp, error) {
	file, err := os.Open(path)
	if err != nil {
		return Stamp{}, err
	}
	defer file.Close()
	const limit = 32 * 1024 * 1024
	content, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return Stamp{}, err
	}
	if len(content) > limit {
		return Stamp{}, fmt.Errorf("game stamp exceeds size limit")
	}
	var stamp Stamp
	if err := json.Unmarshal(content, &stamp); err != nil {
		return Stamp{}, fmt.Errorf("decode game stamp %s: %w", path, err)
	}
	if stamp.Kind != Kind || stamp.SchemaVersion != SchemaVersion {
		return Stamp{}, fmt.Errorf("invalid game stamp marker in %s", path)
	}
	if stamp.AppID == 0 || !supportedProvider(stamp.Provider) || len(stamp.Achievements) == 0 {
		return Stamp{}, fmt.Errorf("invalid game stamp identity in %s", path)
	}
	seen := make(map[string]bool)
	for _, achievement := range stamp.Achievements {
		key := achievement.Provider + ":" + achievement.SourceID
		if !supportedProvider(achievement.Provider) || strings.TrimSpace(achievement.SourceID) == "" || seen[key] {
			return Stamp{}, fmt.Errorf("invalid achievement identity in %s", path)
		}
		if achievement.SteamStatus != "detected" && achievement.SteamStatus != "failed" && achievement.SteamStatus != "synced" {
			return Stamp{}, fmt.Errorf("invalid achievement status in %s", path)
		}
		seen[key] = true
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

	// Go uses MoveFileEx(REPLACE_EXISTING) on Windows. Keep the old file in place
	// until the complete replacement is ready, including when replacement fails.
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace game stamp: %w", err)
	}
	return nil
}
