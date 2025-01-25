// Package ai defines the interface for language model clients.
package ai

import "context"

// LLMClient is the interface that all language model clients must implement.
type LLMClient interface {
	// GetPatch takes a prompt and returns a JSON string containing the patches to apply.
	GetPatch(ctx context.Context, prompt string) (string, error)
}
