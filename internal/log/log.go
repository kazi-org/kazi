// Package log provides debug logging functionality.
package log

import (
	"fmt"
	"os"
)

var debugEnabled bool

// EnableDebug enables debug logging.
func EnableDebug() {
	debugEnabled = true
}

// Debug logs a debug message if debug mode is enabled.
func Debug(format string, args ...interface{}) {
	if debugEnabled {
		fmt.Fprintf(os.Stderr, "[DEBUG] "+format+"\n", args...)
	}
}

// Info logs an info message.
func Info(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "[INFO] "+format+"\n", args...)
}

// Error logs an error message.
func Error(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "[ERROR] "+format+"\n", args...)
}
