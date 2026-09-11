package events

import "testing"

func TestZeroHistoryLimitKeepsCompleteSession(t *testing.T) {
	broker := NewBroker(0)
	for _, line := range []string{"one", "two", "three"} {
		broker.Publish(line)
	}
	_, history, unsubscribe := broker.Subscribe()
	defer unsubscribe()
	if len(history) != 3 {
		t.Fatalf("history length=%d, want 3", len(history))
	}
}
