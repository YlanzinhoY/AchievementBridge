package games

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCatalogAndRuntimeDetectionAreOwnedByGo(t *testing.T) {
	root := t.TempDir()
	gameDir := filepath.Join(root, "steamapps", "common", "Example")
	if err := os.MkdirAll(gameDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := `"AppState" { "appid" "42" "name" "Example" "installdir" "Example" }`
	if err := os.WriteFile(filepath.Join(root, "steamapps", "appmanifest_42.acf"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gameDir, "steam_api64.dll"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gameDir, "configs.main.ini"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	catalog, err := Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog.Apps) != 1 || catalog.Apps[0].AppID != 42 {
		t.Fatalf("unexpected catalog: %+v", catalog.Apps)
	}
	runtimes := DetectRuntime(catalog.Apps[0])
	if len(runtimes) < 2 || runtimes[0].Provider != "gse" || runtimes[0].Confidence < 60 {
		t.Fatalf("unexpected runtime detection: %+v", runtimes)
	}
}
