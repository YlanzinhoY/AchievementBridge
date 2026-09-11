//go:build windows

package games

import (
	"fmt"
	"syscall"
	"unsafe"
)

type Process struct {
	PID            uint32
	Name           string
	ExecutablePath string
}

const (
	th32csSnapProcess       = 0x00000002
	processQueryLimitedInfo = 0x1000
	invalidHandleValue      = ^uintptr(0)
)

type processEntry32 struct {
	Size              uint32
	Usage             uint32
	ProcessID         uint32
	DefaultHeapID     uintptr
	ModuleID          uint32
	Threads           uint32
	ParentProcessID   uint32
	PriorityClassBase int32
	Flags             uint32
	ExeFile           [260]uint16
}

var (
	kernel32                   = syscall.NewLazyDLL("kernel32.dll")
	createToolhelp32Snapshot   = kernel32.NewProc("CreateToolhelp32Snapshot")
	process32FirstW            = kernel32.NewProc("Process32FirstW")
	process32NextW             = kernel32.NewProc("Process32NextW")
	openProcess                = kernel32.NewProc("OpenProcess")
	queryFullProcessImageNameW = kernel32.NewProc("QueryFullProcessImageNameW")
	closeHandle                = kernel32.NewProc("CloseHandle")
)

func ListProcesses() ([]Process, error) {
	handle, _, callErr := createToolhelp32Snapshot.Call(th32csSnapProcess, 0)
	if handle == invalidHandleValue {
		return nil, fmt.Errorf("CreateToolhelp32Snapshot: %w", callErr)
	}
	defer closeHandle.Call(handle)
	entry := processEntry32{Size: uint32(unsafe.Sizeof(processEntry32{}))}
	ok, _, _ := process32FirstW.Call(handle, uintptr(unsafe.Pointer(&entry)))
	if ok == 0 {
		return nil, fmt.Errorf("Process32FirstW failed")
	}
	result := make([]Process, 0, 256)
	for {
		name := syscall.UTF16ToString(entry.ExeFile[:])
		if path := processImagePath(entry.ProcessID); path != "" {
			result = append(result, Process{PID: entry.ProcessID, Name: name, ExecutablePath: path})
		}
		entry.Size = uint32(unsafe.Sizeof(processEntry32{}))
		next, _, _ := process32NextW.Call(handle, uintptr(unsafe.Pointer(&entry)))
		if next == 0 {
			break
		}
	}
	return result, nil
}

func processImagePath(pid uint32) string {
	handle, _, _ := openProcess.Call(processQueryLimitedInfo, 0, uintptr(pid))
	if handle == 0 {
		return ""
	}
	defer closeHandle.Call(handle)
	buffer := make([]uint16, 32768)
	length := uint32(len(buffer))
	ok, _, _ := queryFullProcessImageNameW.Call(
		handle,
		0,
		uintptr(unsafe.Pointer(&buffer[0])),
		uintptr(unsafe.Pointer(&length)),
	)
	if ok == 0 || length == 0 {
		return ""
	}
	return syscall.UTF16ToString(buffer[:length])
}
