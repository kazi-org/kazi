package memory

import "context"

// CodeSource is a single-responsibility interface for retrieving code lines or references.
type CodeSource interface {
	GetCode(ctx context.Context, query string) (string, error)
}
