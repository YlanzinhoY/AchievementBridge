package monitor

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/games"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/providers"
)

type scriptedFactory struct{ watcher *scriptedWatcher }

func (scriptedFactory) Provider() string                                 { return "gse" }
func (f scriptedFactory) Open(providers.Game) (providers.Watcher, error) { return f.watcher, nil }

type scriptedWatcher struct {
	snapshots []providers.Snapshot
	index     int
	closed    bool
}

func (*scriptedWatcher) Provider() string { return "gse" }
func (w *scriptedWatcher) Close() error   { w.closed = true; return nil }
func (w *scriptedWatcher) Snapshot(context.Context) (providers.Snapshot, error) {
	if len(w.snapshots) == 0 {
		return nil, providers.ErrStateUnavailable
	}
	index := w.index
	if index >= len(w.snapshots) {
		index = len(w.snapshots) - 1
	}
	if w.index < len(w.snapshots)-1 {
		w.index++
	}
	return w.snapshots[index], nil
}

func TestSessionStartsOnGameOpenAndPerformsFinalPoll(t *testing.T) {
	root := t.TempDir()
	gameDir := filepath.Join(root, "Game")
	if err := os.MkdirAll(gameDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gameDir, "configs.main.ini"), []byte("[main]"), 0o644); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(gameDir, "game.exe")
	watcher := &scriptedWatcher{snapshots: []providers.Snapshot{
		{"OLD": {Unlocked: true, Timestamp: 10}},
		{"OLD": {Unlocked: true, Timestamp: 10}, "LIVE": {Unlocked: true, Timestamp: 20}},
		{"OLD": {Unlocked: true, Timestamp: 10}, "LIVE": {Unlocked: true, Timestamp: 20}, "ON_EXIT": {Unlocked: true, Timestamp: 30}},
	}}
	running := true
	var received []providers.Event
	catalog := games.Catalog{Apps: []games.Installed{{AppID: 42, Name: "Game", InstallDir: gameDir}}}
	manager, err := New(Options{
		Catalog:     &catalog,
		JournalPath: filepath.Join(root, "journal.jsonl"),
		SupportRoot: filepath.Join(root, "support"),
		FinalGrace:  time.Millisecond,
		Factories:   []providers.Factory{scriptedFactory{watcher}},
		ProcessLister: func() ([]games.Process, error) {
			if !running {
				return nil, nil
			}
			return []games.Process{{PID: 7, Name: "game.exe", ExecutablePath: executable}}, nil
		},
		OnAchievement: func(event providers.Event) { received = append(received, event) },
	})
	if err != nil {
		t.Fatal(err)
	}
	manager.refreshSessions(context.Background())
	if len(manager.sessions) != 1 {
		t.Fatalf("sessions=%d, want 1", len(manager.sessions))
	}
	manager.pollProviders(context.Background())
	running = false
	manager.refreshSessions(context.Background())
	time.Sleep(2 * time.Millisecond)
	manager.pollProviders(context.Background())
	if len(received) != 2 || received[0].Achievement != "LIVE" || received[1].Achievement != "ON_EXIT" {
		t.Fatalf("unexpected live events: %+v", received)
	}
	if len(manager.sessions) != 0 || !watcher.closed {
		t.Fatal("session watcher did not close")
	}
	if manager.journal.HasEvent("gse", 42, "OLD") == false {
		t.Fatal("initial state was not baselined")
	}
}

func TestFirstProviderFileCreatedDuringSessionIsLive(t *testing.T) {
	root := t.TempDir()
	gameDir := filepath.Join(root, "Game")
	_ = os.MkdirAll(gameDir, 0o755)
	_ = os.WriteFile(filepath.Join(gameDir, "configs.main.ini"), []byte(""), 0o644)
	watcher := &scriptedWatcher{}
	var received []providers.Event
	catalog := games.Catalog{Apps: []games.Installed{{AppID: 77, Name: "Game", InstallDir: gameDir}}}
	manager, err := New(Options{
		Catalog: &catalog, JournalPath: filepath.Join(root, "journal.jsonl"), SupportRoot: filepath.Join(root, "support"),
		Factories: []providers.Factory{scriptedFactory{watcher}},
		ProcessLister: func() ([]games.Process, error) {
			return []games.Process{{PID: 8, ExecutablePath: filepath.Join(gameDir, "game.exe")}}, nil
		},
		OnAchievement: func(event providers.Event) { received = append(received, event) },
	})
	if err != nil {
		t.Fatal(err)
	}
	manager.refreshSessions(context.Background())
	watcher.snapshots = []providers.Snapshot{{"FIRST": {Unlocked: true, Timestamp: 50}}}
	manager.pollProviders(context.Background())
	if len(received) != 1 || received[0].Achievement != "FIRST" || received[0].Recovered {
		t.Fatalf("first live snapshot was not emitted: %+v", received)
	}
}
