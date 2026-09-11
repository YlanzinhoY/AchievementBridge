package providers

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type GSEFactory struct {
	Roaming string
}

func (GSEFactory) Provider() string { return "gse" }

func (f GSEFactory) Open(game Game) (Watcher, error) {
	roaming := f.Roaming
	if roaming == "" {
		roaming = os.Getenv("APPDATA")
	}
	if roaming == "" {
		return nil, fmt.Errorf("APPDATA is unavailable")
	}
	id := strconv.FormatUint(uint64(game.AppID), 10)
	paths := uniquePaths([]string{
		filepath.Join(roaming, "GSE Saves", id, "achievements.json"),
		filepath.Join(roaming, "Goldberg SteamEmu Saves", id, "achievements.json"),
	})
	return &fileWatcher{provider: "gse", paths: func() []string { return paths }, parse: parseGSE}, nil
}

func parseGSE(_ string, bytes []byte) (Snapshot, error) {
	var values map[string]any
	if err := json.Unmarshal(bytes, &values); err != nil {
		return nil, err
	}
	result := make(Snapshot, len(values))
	for id, raw := range values {
		state, ok := jsonAchievementState(raw)
		if ok {
			result[id] = state
		}
	}
	return result, nil
}

func jsonAchievementState(raw any) (AchievementState, bool) {
	switch value := raw.(type) {
	case bool:
		return AchievementState{Unlocked: value}, true
	case float64:
		return AchievementState{Unlocked: value != 0}, true
	case string:
		return AchievementState{Unlocked: textTruthy(value)}, true
	case map[string]any:
		earned, found := first(value, "earned", "Earned", "achieved", "Achieved", "unlocked", "Unlocked", "HaveAchieved", "State")
		if !found {
			return AchievementState{}, false
		}
		timestamp, _ := first(value, "earned_time", "unlock_time", "UnlockTime", "HaveAchievedTime", "DateAchieved", "Time")
		return AchievementState{Unlocked: truthy(earned), Timestamp: integer(timestamp)}, true
	default:
		return AchievementState{}, false
	}
}

func first(values map[string]any, keys ...string) (any, bool) {
	for _, key := range keys {
		if value, exists := values[key]; exists {
			return value, true
		}
	}
	return nil, false
}

func truthy(value any) bool {
	switch item := value.(type) {
	case bool:
		return item
	case float64:
		return item != 0
	case string:
		return textTruthy(item)
	default:
		return false
	}
}

func textTruthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "unlocked", "achieved":
		return true
	default:
		return false
	}
}

func integer(value any) int64 {
	switch item := value.(type) {
	case float64:
		return int64(item)
	case string:
		parsed, _ := strconv.ParseInt(strings.TrimSpace(item), 10, 64)
		return parsed
	default:
		return 0
	}
}
