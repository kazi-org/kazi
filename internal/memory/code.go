package memory

import "context"

// CodeSource fetches code references or lines. Single responsibility.
type CodeSource interface {
	GetCode(ctx context.Context, query string) (string, error)
}
