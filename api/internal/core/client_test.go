package core

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"
)

func startProtocolServer(t *testing.T, handler func(request) any) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		line, readErr := bufio.NewReader(connection).ReadBytes('\n')
		if readErr != nil {
			return
		}
		var received request
		if json.Unmarshal(line, &received) != nil {
			return
		}
		_ = json.NewEncoder(connection).Encode(handler(received))
	}()
	return listener.Addr().String()
}

func TestClientCallsVersionedCoreProtocol(t *testing.T) {
	address := startProtocolServer(t, func(received request) any {
		if received.Version != ProtocolVersion || received.Method != "health" {
			t.Errorf("unexpected request: %#v", received)
		}
		return map[string]any{
			"version": ProtocolVersion,
			"id":      received.ID,
			"ok":      true,
			"result":  map[string]string{"status": "ready"},
		}
	})
	client := NewClient(address)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var result map[string]string
	if err := client.Call(ctx, "health", struct{}{}, &result); err != nil {
		t.Fatal(err)
	}
	if result["status"] != "ready" {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestClientReturnsStructuredCoreError(t *testing.T) {
	address := startProtocolServer(t, func(received request) any {
		return map[string]any{
			"version": ProtocolVersion,
			"id":      received.ID,
			"ok":      false,
			"error": map[string]string{
				"code":    "AchievementNotFound",
				"message": "AchievementNotFound",
			},
		}
	})
	client := NewClient(address)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	err := client.Call(ctx, "preview_achievement", struct{}{}, nil)
	remote, ok := err.(*RemoteError)
	if !ok || remote.Code != "AchievementNotFound" {
		t.Fatalf("unexpected error: %#v", err)
	}
}
