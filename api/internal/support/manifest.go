package support

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Manifest struct {
	SteamAppID      uint32       `json:"steam_app_id"`
	Game            string       `json:"game"`
	GameDirectory   string       `json:"game_directory"`
	Provider        string       `json:"provider"`
	ProviderProduct uint32       `json:"provider_product_id"`
	SourceState     string       `json:"source_state"`
	CatalogCount    uint64       `json:"catalog_count"`
	PreparedAt      int64        `json:"prepared_at"`
	Mapping         string       `json:"mapping"`
	Capabilities    Capabilities `json:"capabilities"`
}

type Capabilities struct {
	Detect      bool `json:"detect"`
	Monitor     bool `json:"monitor"`
	MapToSteam  bool `json:"map_to_steam"`
	SyncToSteam bool `json:"sync_to_steam"`
	Popup       bool `json:"popup"`
}

type Achievement struct {
	APIName     string
	Name        string
	Description string
}

type PrepareResult struct {
	Manifest     Manifest
	SchemaPath   string
	ConfigPath   string
	ManifestPath string
}

func LoadAll(root string) map[uint32]Manifest {
	result := make(map[uint32]Manifest)
	paths, _ := filepath.Glob(filepath.Join(root, "games", "*", "support.json"))
	for _, path := range paths {
		bytes, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var manifest Manifest
		if json.Unmarshal(bytes, &manifest) == nil && manifest.SteamAppID != 0 && manifest.Provider != "" {
			result[manifest.SteamAppID] = manifest
		}
	}
	return result
}

func DefaultRoot() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "AchievementBridge", "support")
}

func PrepareUplayR2(root string, appID uint32, game, gameDirectory string, achievements []Achievement) (PrepareResult, error) {
	if appID == 0 || gameDirectory == "" || len(achievements) == 0 {
		return PrepareResult{}, fmt.Errorf("invalid Uplay R2 support input")
	}
	if !hasAnyFile(gameDirectory, "upc_r2_loader.dll", "upc_r2_loader64.dll", "uplay_r2_loader.dll", "uplay_r2_loader64.dll") {
		return PrepareResult{}, fmt.Errorf("Uplay R2 loader was not found")
	}
	schema, err := renderUplaySchema(achievements)
	if err != nil {
		return PrepareResult{}, err
	}
	schemaPath := filepath.Join(gameDirectory, "achievements_schema.json")
	if err := backupOnce(schemaPath); err != nil {
		return PrepareResult{}, err
	}
	if err := writeAtomic(schemaPath, schema); err != nil {
		return PrepareResult{}, err
	}

	configPath := firstExisting(gameDirectory, "upc_r2.ini", "uplay_r2.ini")
	if configPath == "" {
		configPath = filepath.Join(gameDirectory, "upc_r2.ini")
	}
	config := []byte("[Settings]\r\nLanguage = en-US\r\nAchievements = 1\r\nLogging = 1\r\nSaveType = 0\r\nSavePath =\r\nSaveExtension = .save\r\n")
	if current, readErr := os.ReadFile(configPath); readErr == nil {
		config = enableAchievements(current)
	}
	if err := backupOnce(configPath); err != nil {
		return PrepareResult{}, err
	}
	if err := writeAtomic(configPath, config); err != nil {
		return PrepareResult{}, err
	}

	all := LoadAll(root)
	preparedAt := time.Now().Unix()
	if prior, exists := all[appID]; exists && prior.PreparedAt > 0 {
		preparedAt = prior.PreparedAt
	}
	productID := readProductID(gameDirectory)
	if productID == 0 {
		productID = recentUnclaimedProductID(all, appID, preparedAt)
	}
	source := ""
	if productID != 0 {
		candidate := filepath.Join(os.Getenv("APPDATA"), "Goldberg UplayEmu Saves", strconv.FormatUint(uint64(productID), 10), "achievements.json")
		if fileExists(candidate) {
			source = candidate
		}
	}
	complete := productID != 0 && source != ""
	manifest := Manifest{
		SteamAppID: appID, Game: game, GameDirectory: gameDirectory,
		Provider: "uplay_r2", ProviderProduct: productID, SourceState: source,
		CatalogCount: uint64(len(achievements)), PreparedAt: time.Now().Unix(), Mapping: "numeric_suffix",
		Capabilities: Capabilities{Detect: true, Monitor: true, MapToSteam: true, SyncToSteam: complete, Popup: true},
	}
	manifestPath := filepath.Join(root, "games", strconv.FormatUint(uint64(appID), 10), "support.json")
	encoded, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return PrepareResult{}, err
	}
	encoded = append(encoded, '\n')
	if err := writeAtomic(manifestPath, encoded); err != nil {
		return PrepareResult{}, err
	}
	return PrepareResult{Manifest: manifest, SchemaPath: schemaPath, ConfigPath: configPath, ManifestPath: manifestPath}, nil
}

func renderUplaySchema(achievements []Achievement) ([]byte, error) {
	ordered := append([]Achievement(nil), achievements...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return numericSuffix(ordered[i].APIName) < numericSuffix(ordered[j].APIName)
	})
	result := make(map[string]map[string]any, len(ordered))
	for _, achievement := range ordered {
		id := numericSuffix(achievement.APIName)
		if id == 0 {
			return nil, fmt.Errorf("achievement %q has no numeric suffix", achievement.APIName)
		}
		key := strconv.FormatUint(id, 10)
		if _, duplicate := result[key]; duplicate {
			return nil, fmt.Errorf("duplicate provider objective %s", key)
		}
		result[key] = map[string]any{"displayName": achievement.Name, "description": achievement.Description, "earned": 0}
	}
	return json.MarshalIndent(result, "", "  ")
}

func numericSuffix(value string) uint64 {
	start := len(value)
	for start > 0 && value[start-1] >= '0' && value[start-1] <= '9' {
		start--
	}
	if start == len(value) {
		return 0
	}
	parsed, _ := strconv.ParseUint(value[start:], 10, 64)
	return parsed
}

func enableAchievements(bytes []byte) []byte {
	lines := strings.Split(strings.ReplaceAll(string(bytes), "\r\n", "\n"), "\n")
	found := false
	for index, line := range lines {
		key, _, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && strings.EqualFold(strings.TrimSpace(key), "Achievements") {
			lines[index] = "Achievements = 1"
			found = true
		}
	}
	if !found {
		lines = append(lines, "Achievements = 1")
	}
	return []byte(strings.Join(lines, "\r\n"))
}

var productPattern = regexp.MustCompile(`(?i)appid\s*\((\d+)\)`)

func readProductID(gameDirectory string) uint32 {
	var selected uint32
	for _, name := range []string{"upc_r2.log", "uplay_r2.log"} {
		bytes, err := os.ReadFile(filepath.Join(gameDirectory, name))
		if err != nil {
			continue
		}
		for _, match := range productPattern.FindAllSubmatch(bytes, -1) {
			value, _ := strconv.ParseUint(string(match[1]), 10, 32)
			if value != 0 {
				selected = uint32(value)
			}
		}
	}
	return selected
}

func recentUnclaimedProductID(all map[uint32]Manifest, appID uint32, since int64) uint32 {
	root := filepath.Join(os.Getenv("APPDATA"), "Goldberg UplayEmu Saves")
	entries, _ := os.ReadDir(root)
	claimed := make(map[uint32]struct{})
	for id, manifest := range all {
		if id != appID && manifest.ProviderProduct != 0 {
			claimed[manifest.ProviderProduct] = struct{}{}
		}
	}
	var selected uint32
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		value, err := strconv.ParseUint(entry.Name(), 10, 32)
		if err != nil || value == 0 {
			continue
		}
		productID := uint32(value)
		if _, used := claimed[productID]; used {
			continue
		}
		info, err := os.Stat(filepath.Join(root, entry.Name(), "achievements.json"))
		if err != nil || info.ModTime().Unix() < since {
			continue
		}
		if selected != 0 && selected != productID {
			return 0
		}
		selected = productID
	}
	return selected
}

func hasAnyFile(root string, names ...string) bool { return firstExisting(root, names...) != "" }
func firstExisting(root string, names ...string) string {
	for _, name := range names {
		path := filepath.Join(root, name)
		if fileExists(path) {
			return path
		}
	}
	return ""
}
func fileExists(path string) bool { info, err := os.Stat(path); return err == nil && !info.IsDir() }

func backupOnce(path string) error {
	bytes, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	backup := path + ".achievement-bridge.bak"
	if fileExists(backup) {
		return nil
	}
	return writeAtomic(backup, bytes)
}

func writeAtomic(path string, bytes []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".achievement-bridge-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err = temporary.Write(bytes); err == nil {
		err = temporary.Sync()
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	_ = os.Remove(path)
	return os.Rename(temporaryPath, path)
}
