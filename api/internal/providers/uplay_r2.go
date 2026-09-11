package providers

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

type UplayR2Factory struct {
	Roaming string
}

func (UplayR2Factory) Provider() string { return "uplay_r2" }

func (f UplayR2Factory) Open(game Game) (Watcher, error) {
	roaming := f.Roaming
	if roaming == "" {
		roaming = os.Getenv("APPDATA")
	}
	if roaming == "" {
		return nil, fmt.Errorf("APPDATA is unavailable")
	}
	productID := game.ProviderProductID
	if productID == 0 {
		productID = game.AppID
	}
	id := strconv.FormatUint(uint64(productID), 10)
	paths := uniquePaths([]string{game.SourceState, filepath.Join(roaming, "Goldberg UplayEmu Saves", id, "achievements.json")})
	return &fileWatcher{provider: "uplay_r2", paths: func() []string { return paths }, parse: parseGSE}, nil
}
