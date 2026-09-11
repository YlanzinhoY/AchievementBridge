package support

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrepareUplayR2OwnsProviderConfigurationInGo(t *testing.T) {
	root := t.TempDir()
	appData := filepath.Join(root, "roaming")
	t.Setenv("APPDATA", appData)
	gameDir := filepath.Join(root, "game")
	if err := os.MkdirAll(gameDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gameDir, "uplay_r2_loader64.dll"), []byte("loader"), 0o644); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(gameDir, "uplay_r2.ini")
	if err := os.WriteFile(configPath, []byte("[Settings]\r\nAchievements = 0\r\nLogging = 0\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gameDir, "uplay_r2.log"), []byte("UPC_Init -> appid (64181)\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(appData, "Goldberg UplayEmu Saves", "64181", "achievements.json")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte(`{"1":{"earned":false}}`), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := PrepareUplayR2(filepath.Join(root, "support"), 123, "Game", gameDir, []Achievement{
		{APIName: "Game_Ach_1", Name: "First", Description: "Begin"},
		{APIName: "Game_Ach_2", Name: "Second", Description: "Continue"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Manifest.Capabilities.SyncToSteam || result.Manifest.ProviderProduct != 64181 || result.Manifest.SourceState != statePath {
		t.Fatalf("unexpected manifest: %+v", result.Manifest)
	}
	config, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(config), "Achievements = 1") {
		t.Fatalf("achievements were not enabled: %s", config)
	}
	if _, err := os.Stat(configPath + ".achievement-bridge.bak"); err != nil {
		t.Fatal("original config was not backed up")
	}
	var schema map[string]map[string]any
	bytes, err := os.ReadFile(result.SchemaPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(bytes, &schema); err != nil {
		t.Fatal(err)
	}
	if schema["2"]["displayName"] != "Second" {
		t.Fatalf("unexpected schema: %+v", schema)
	}
}
