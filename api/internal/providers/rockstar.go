package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type NativeSampler func(context.Context, uint32) (Snapshot, error)

type RockstarFactory struct {
	Public       string
	NativeSample NativeSampler
}

func (RockstarFactory) Provider() string { return "rockstar" }

func (f RockstarFactory) Open(game Game) (Watcher, error) {
	public := f.Public
	if public == "" {
		public = os.Getenv("PUBLIC")
	}
	return &rockstarWatcher{
		game:         game,
		root:         filepath.Join(public, "Documents", "Socialclub"),
		nativeSample: f.NativeSample,
	}, nil
}

type rockstarWatcher struct {
	game         Game
	root         string
	nativeSample NativeSampler
}

func (*rockstarWatcher) Provider() string { return "rockstar" }
func (*rockstarWatcher) Close() error     { return nil }

func (w *rockstarWatcher) Snapshot(ctx context.Context) (Snapshot, error) {
	if w.nativeSample != nil {
		if state, err := w.nativeSample(ctx, w.game.AppID); err == nil {
			return state, nil
		}
	}
	path := w.findStateFile(ctx)
	if path == "" {
		return nil, ErrStateUnavailable
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseRockstarState(path, bytes)
}

func (w *rockstarWatcher) findStateFile(ctx context.Context) string {
	var selected string
	var modified int64
	wantedID := strconv.FormatUint(uint64(w.game.AppID), 10)
	wantedTitle := normalizeTitle(w.game.Name)
	_ = filepath.WalkDir(w.root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || ctx.Err() != nil || entry.IsDir() {
			return nil
		}
		name := strings.ToLower(entry.Name())
		if strings.HasSuffix(name, ".bak") || (!isRockstarStateName(name)) {
			return nil
		}
		normalizedPath := normalizeTitle(path)
		if !strings.Contains(normalizedPath, wantedID) && wantedTitle != "" && !strings.Contains(normalizedPath, wantedTitle) {
			return nil
		}
		info, statErr := entry.Info()
		if statErr == nil && info.ModTime().UnixNano() >= modified {
			selected, modified = path, info.ModTime().UnixNano()
		}
		return nil
	})
	return selected
}

func isRockstarStateName(name string) bool {
	if strings.HasPrefix(name, "sgta") && !strings.Contains(name, ".") {
		return true
	}
	switch name {
	case "achievements.ini", "achievements.json", "achiev.ini", "stats.ini", "accomplishments.json", "awards.json", "user_stats.ini", "stats.json":
		return true
	default:
		return false
	}
}

func normalizeTitle(value string) string {
	var result strings.Builder
	for _, current := range strings.ToLower(value) {
		if current >= 'a' && current <= 'z' || current >= '0' && current <= '9' {
			result.WriteRune(current)
		}
	}
	return result.String()
}

func parseRockstarState(path string, bytes []byte) (Snapshot, error) {
	trimmed := strings.TrimSpace(string(bytes))
	if trimmed == "" {
		return nil, fmt.Errorf("empty Rockstar state")
	}
	if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		var raw any
		if err := json.Unmarshal(bytes, &raw); err != nil {
			return nil, err
		}
		result := make(Snapshot)
		appendRockstarJSON(result, raw)
		if len(result) == 0 {
			return nil, fmt.Errorf("unsupported Rockstar JSON state")
		}
		return result, nil
	}
	if strings.HasPrefix(strings.ToLower(filepath.Base(path)), "sgta") {
		return nil, ErrStateUnavailable
	}
	return parseRockstarINI(trimmed)
}

func appendRockstarJSON(result Snapshot, raw any) {
	switch value := raw.(type) {
	case map[string]any:
		if nested, exists := value["Achievements"]; exists {
			appendRockstarJSON(result, nested)
			return
		}
		if nested, exists := value["achievements"]; exists {
			appendRockstarJSON(result, nested)
			return
		}
		for id, state := range value {
			if parsed, ok := jsonAchievementState(state); ok {
				result[id] = parsed
			}
		}
	case []any:
		for _, item := range value {
			object, ok := item.(map[string]any)
			if !ok {
				continue
			}
			idValue, found := first(object, "api_name", "name", "id", "AchievementId")
			if !found {
				continue
			}
			id := fmt.Sprint(idValue)
			if parsed, ok := jsonAchievementState(object); ok {
				result[id] = parsed
			}
		}
	}
}

func parseRockstarINI(text string) (Snapshot, error) {
	result := make(Snapshot)
	section := ""
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			if strings.EqualFold(section, "Achievements") || strings.EqualFold(section, "SteamAchievements") {
				section = ""
			}
			continue
		}
		if section == "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		state := result[section]
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "achieved", "earned", "unlocked", "haveachieved", "state":
			state.Unlocked = textTruthy(value)
		case "unlocktime", "earned_time", "dateachieved", "haveachievedtime", "time":
			state.Timestamp, _ = strconv.ParseInt(strings.TrimSpace(value), 10, 64)
		default:
			continue
		}
		result[section] = state
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("unsupported Rockstar INI state")
	}
	return result, nil
}
