package providers

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

type fileWatcher struct {
	provider string
	paths    func() []string
	parse    func(string, []byte) (Snapshot, error)
}

func (w *fileWatcher) Provider() string { return w.provider }
func (w *fileWatcher) Close() error     { return nil }

func (w *fileWatcher) Snapshot(ctx context.Context) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var lastErr error
	for _, candidate := range w.paths() {
		bytes, err := os.ReadFile(candidate)
		if err != nil {
			if !os.IsNotExist(err) {
				lastErr = err
			}
			continue
		}
		state, err := w.parse(candidate, bytes)
		if err == nil {
			return state, nil
		}
		lastErr = fmt.Errorf("parse %s: %w", filepath.Base(candidate), err)
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, ErrStateUnavailable
}

func uniquePaths(paths []string) []string {
	seen := make(map[string]struct{}, len(paths))
	result := make([]string, 0, len(paths))
	for _, path := range paths {
		if path == "" {
			continue
		}
		key := filepath.Clean(path)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, key)
	}
	return result
}
