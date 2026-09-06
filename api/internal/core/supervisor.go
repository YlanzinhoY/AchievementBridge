package core

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

type Supervisor struct {
	client     *Client
	executable string
	address    string
	steamRoot  string
	stdout     io.Writer
	stderr     io.Writer

	mu    sync.Mutex
	owned *exec.Cmd
}

func NewSupervisor(client *Client, executable, address, steamRoot string) *Supervisor {
	return &Supervisor{
		client:     client,
		executable: executable,
		address:    address,
		steamRoot:  steamRoot,
		stdout:     os.Stdout,
		stderr:     os.Stderr,
	}
}

func (s *Supervisor) Ensure(ctx context.Context) error {
	probeContext, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	err := s.client.Call(probeContext, "health", struct{}{}, nil)
	cancel()
	if err == nil {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	probeContext, cancel = context.WithTimeout(ctx, 500*time.Millisecond)
	err = s.client.Call(probeContext, "health", struct{}{}, nil)
	cancel()
	if err == nil {
		return nil
	}
	if s.owned != nil && s.owned.ProcessState == nil {
		return s.awaitReady(ctx)
	}

	host, portText, err := net.SplitHostPort(s.address)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return fmt.Errorf("invalid Zig core loopback address %q", s.address)
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		return fmt.Errorf("invalid Zig core port %q", portText)
	}
	arguments := []string{"serve", "--port", strconv.FormatUint(port, 10)}
	if s.steamRoot != "" {
		arguments = append(arguments, "--steam-root", s.steamRoot)
	}
	command := exec.Command(s.executable, arguments...)
	command.Stdout = s.stdout
	command.Stderr = s.stderr
	if err := command.Start(); err != nil {
		return fmt.Errorf("start Zig core: %w", err)
	}
	s.owned = command
	go func() {
		_ = command.Wait()
	}()
	return s.awaitReady(ctx)
}

func (s *Supervisor) awaitReady(ctx context.Context) error {
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return fmt.Errorf("Zig core did not become ready at %s", s.address)
		case <-ticker.C:
			probeContext, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
			err := s.client.Call(probeContext, "health", struct{}{}, nil)
			cancel()
			if err == nil {
				return nil
			}
		}
	}
}

func (s *Supervisor) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.owned != nil && s.owned.Process != nil && s.owned.ProcessState == nil {
		_ = s.owned.Process.Kill()
	}
	s.owned = nil
}
