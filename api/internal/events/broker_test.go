package events

import (
	"testing"
	"time"
)

func TestBrokerPublishesHistoryAndLiveEvents(t *testing.T) {
	broker := NewBroker(2)
	broker.Publish("first")
	broker.Publish("second")
	broker.Publish("third")

	stream, history, unsubscribe := broker.Subscribe()
	defer unsubscribe()
	if len(history) != 2 || history[0] != "second" || history[1] != "third" {
		t.Fatalf("unexpected history: %#v", history)
	}
	broker.Publish("live")
	select {
	case line := <-stream:
		if line != "live" {
			t.Fatalf("unexpected live event %q", line)
		}
	case <-time.After(time.Second):
		t.Fatal("live event was not delivered")
	}
}

func TestLineWriterPublishesCompleteLines(t *testing.T) {
	var lines []string
	writer := NewLineWriter(func(line string) { lines = append(lines, line) })
	if _, err := writer.Write([]byte("one\r\ntw")); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("o\npartial")); err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 || lines[0] != "one" || lines[1] != "two" {
		t.Fatalf("unexpected lines: %#v", lines)
	}
}

func TestClearHistoryDoesNotReplayPreviousSession(t *testing.T) {
	broker := NewBroker(10)
	broker.Publish("old achievement")
	broker.ClearHistory()
	broker.Publish("new session")

	_, history, unsubscribe := broker.Subscribe()
	defer unsubscribe()
	if len(history) != 1 || history[0] != "new session" {
		t.Fatalf("unexpected history after reset: %#v", history)
	}
}
