package memory

import "context"

// DocSource fetches doc references or paragraphs. Single responsibility.
type DocSource interface {
	GetDoc(ctx context.Context, query string) (string, error)
}
