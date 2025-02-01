package memory

import "context"

// LogSource fetches ephemeral log content or messages.
type LogSource interface {
	GetLog(ctx context.Context, query string) (string, error)
}
