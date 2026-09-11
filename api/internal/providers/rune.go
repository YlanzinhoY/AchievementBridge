package providers

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type RUNEFactory struct {
	Public string
}

func (RUNEFactory) Provider() string { return "rune" }

func (f RUNEFactory) Open(game Game) (Watcher, error) {
	public := f.Public
	if public == "" {
		public = os.Getenv("PUBLIC")
	}
	if public == "" {
		drive := os.Getenv("SystemDrive")
		if drive == "" {
			drive = "C:"
		}
		public = filepath.Join(drive+string(os.PathSeparator), "Users", "Public")
	}
	id := strconv.FormatUint(uint64(game.AppID), 10)
	paths := []string{filepath.Join(public, "Documents", "Steam", "RUNE", id, "achievements.ini")}
	return &fileWatcher{provider: "rune", paths: func() []string { return paths }, parse: parseRUNE}, nil
}

func parseRUNE(_ string, bytes []byte) (Snapshot, error) {
	result := make(Snapshot)
	section := ""
	for _, raw := range strings.Split(string(bytes), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			if strings.EqualFold(section, "SteamAchievements") {
				section = ""
			}
			continue
		}
		if section == "" {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		state := result[section]
		switch {
		case strings.EqualFold(strings.TrimSpace(key), "Achieved"):
			state.Unlocked = textTruthy(value)
		case strings.EqualFold(strings.TrimSpace(key), "UnlockTime"):
			state.Timestamp, _ = strconv.ParseInt(strings.TrimSpace(value), 10, 64)
		default:
			continue
		}
		result[section] = state
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("no RUNE achievement sections")
	}
	return result, nil
}
