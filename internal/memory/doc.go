package memory

import "context"

// DocSource handles retrieving doc paragraphs or textual references.
type DocSource interface {
	GetDoc(ctx context.Context, query string) (string, error)
}
