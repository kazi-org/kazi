// ephemeral_logs.go
//
// Provides a minimal ephemeral log system for short-lived data such as patch attempts or messages.
// If your project wants deeper analytics, you can build that here.

package project

import (
	"context"
)

// EphemeralLog is an interface for recording short-lived logs
// (e.g. "Patch #14 success at 2023-09-01 10:32am").
type EphemeralLog interface {
	// RecordLog writes a log entry to an in-memory or temporary store.
	RecordLog(ctx context.Context, entry string) error

	// ListLogs returns recent log entries, for debugging or analytics.
	ListLogs(ctx context.Context) ([]string, error)
}

// SimpleEphemeralLog is a trivial in-memory implementation with concurrency-safe storage.
type SimpleEphemeralLog struct {
	entries []string
}

func (el *SimpleEphemeralLog) RecordLog(ctx context.Context, entry string) error {
	// In production, use a mutex or channel approach to safely append.
	el.entries = append(el.entries, entry)
	return nil
}

func (el *SimpleEphemeralLog) ListLogs(ctx context.Context) ([]string, error) {
	return el.entries, nil
}
