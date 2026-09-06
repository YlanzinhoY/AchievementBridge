//go:build windows

package main

import (
	"fmt"
	"syscall"
)

const (
	processSynchronize = 0x00100000
	waitObjectZero     = 0x00000000
	waitInfinite       = 0xFFFFFFFF
	waitFailed         = 0xFFFFFFFF
)

var (
	kernel32Process     = syscall.NewLazyDLL("kernel32.dll")
	openProcess         = kernel32Process.NewProc("OpenProcess")
	waitForSingleObject = kernel32Process.NewProc("WaitForSingleObject")
	closeProcessHandle  = kernel32Process.NewProc("CloseHandle")
)

func waitForProcessExit(pid int) error {
	if pid <= 0 {
		return fmt.Errorf("invalid parent process id %d", pid)
	}
	handle, _, openError := openProcess.Call(processSynchronize, 0, uintptr(pid))
	if handle == 0 {
		return fmt.Errorf("open parent process %d: %w", pid, openError)
	}
	defer closeProcessHandle.Call(handle)

	result, _, waitError := waitForSingleObject.Call(handle, waitInfinite)
	if result == waitFailed {
		return fmt.Errorf("wait for parent process %d: %w", pid, waitError)
	}
	if result != waitObjectZero {
		return fmt.Errorf("unexpected parent wait result 0x%x", result)
	}
	return nil
}
