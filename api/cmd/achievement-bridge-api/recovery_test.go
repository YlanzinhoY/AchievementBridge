package main

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/core"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/events"
)

type recoveringCore struct {
	mu      sync.Mutex
	ready   bool
	methods []string
}

func (c *recoveringCore) Call(_ context.Context, method string, _ any, _ any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.methods = append(c.methods, method)
	if !c.ready {
		return errors.New("connection refused")
	}
	return nil
}

type recoveringSupervisor struct {
	core       *recoveringCore
	ensureRuns int
	broker     *events.Broker
}

func (s *recoveringSupervisor) Ensure(context.Context) error {
	s.ensureRuns++
	s.core.mu.Lock()
	s.core.ready = true
	s.core.mu.Unlock()
	return nil
}

func (s *recoveringSupervisor) Events() *events.Broker { return s.broker }

func TestCallCoreRestartsCoreAndRestoresMonitor(t *testing.T) {
	client := &recoveringCore{}
	supervisor := &recoveringSupervisor{core: client, broker: events.NewBroker(10)}
	app := &application{core: client, supervisor: supervisor}
	app.rememberMonitor(map[string]any{"interval_ms": uint32(500)})

	if err := app.callCore(context.Background(), "inspect_games", struct{}{}, nil); err != nil {
		t.Fatalf("callCore returned error: %v", err)
	}
	if supervisor.ensureRuns != 1 {
		t.Fatalf("Ensure ran %d times, want 1", supervisor.ensureRuns)
	}

	client.mu.Lock()
	methods := append([]string(nil), client.methods...)
	client.mu.Unlock()
	want := []string{"inspect_games", "health", "start_monitor", "inspect_games"}
	if len(methods) != len(want) {
		t.Fatalf("methods = %v, want %v", methods, want)
	}
	for index := range want {
		if methods[index] != want[index] {
			t.Fatalf("methods = %v, want %v", methods, want)
		}
	}
}

type remoteErrorCore struct{ calls int }

func (c *remoteErrorCore) Call(context.Context, string, any, any) error {
	c.calls++
	return &core.RemoteError{Code: "SetAchievementFailed", Message: "denied"}
}

func TestCallCoreDoesNotRestartForRemoteErrors(t *testing.T) {
	client := &remoteErrorCore{}
	supervisor := &recoveringSupervisor{core: &recoveringCore{}, broker: events.NewBroker(10)}
	app := &application{core: client, supervisor: supervisor}

	err := app.callCore(context.Background(), "preview_achievement", struct{}{}, nil)
	var remote *core.RemoteError
	if !errors.As(err, &remote) {
		t.Fatalf("error = %v, want RemoteError", err)
	}
	if supervisor.ensureRuns != 0 {
		t.Fatalf("Ensure ran %d times for a semantic error", supervisor.ensureRuns)
	}
}
