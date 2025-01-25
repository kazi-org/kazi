//go:build windows
// +build windows

package lsp

import (
	"os"
	"syscall"
)

// signalGracefulShutdown sends CTRL_BREAK_EVENT on Windows for graceful shutdown
func signalGracefulShutdown(process *os.Process) error {
	dll, err := syscall.LoadDLL("kernel32.dll")
	if err != nil {
		return err
	}
	proc, err := dll.FindProc("GenerateConsoleCtrlEvent")
	if err != nil {
		return err
	}
	r1, _, err := proc.Call(syscall.CTRL_BREAK_EVENT, uintptr(process.Pid))
	if r1 == 0 {
		return err
	}
	return nil
}
