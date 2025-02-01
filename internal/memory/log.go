package memory

import "context"

// LogSource fetches logs or ephemeral notes. Single responsibility.
type LogSource interface {
	GetLog(ctx context.Context, query string) (string, error)
}
