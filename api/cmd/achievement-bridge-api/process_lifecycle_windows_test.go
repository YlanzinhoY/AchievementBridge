//go:build windows

package main

import (
	"os/exec"
	"testing"
	"time"
)

func TestWaitForProcessExit(t *testing.T) {
	child := exec.Command("cmd.exe", "/d", "/c", "ping 127.0.0.1 -n 2 >nul")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- waitForProcessExit(child.Process.Pid) }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		_ = child.Process.Kill()
		t.Fatal("parent process watcher did not observe process exit")
	}
	_ = child.Wait()
}
