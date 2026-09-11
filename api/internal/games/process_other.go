//go:build !windows

package games

import "fmt"

type Process struct {
	PID            uint32
	Name           string
	ExecutablePath string
}

func ListProcesses() ([]Process, error) {
	return nil, fmt.Errorf("process discovery is supported only on Windows")
}
