// context.go
//
// Defines the ContextClient interface plus an aggregator approach for merging
// multiple context sources into one consolidated LLM prompt.

package coordinator

import (
	"context"
	"fmt"
	"strings"
)

// ContextClient represents any source of textual context for the LLM. 
// For example, doc references, ephemeral logs, project constraints, chunk data, etc.
//
// key might be something like "domainConstraints", "docs/productContext.md", or "ephemeralLogs" 
// so we can handle different queries for context.
type ContextClient interface {
	GetContext(ctx context.Context, key string) (string, error)
}

// ContextAggregator merges contexts from multiple ContextClient sources 
// under specified keys, returning a single string for the LLM.
type ContextAggregator interface {
	// Aggregate takes a slice of (client, key) pairs, calls each client’s GetContext,
	// and concatenates or merges them into a final string for the LLM.
	Aggregate(ctx context.Context, items []ContextItem) (string, error)
}

// ContextItem holds which client and key to use for retrieving context.
type ContextItem struct {
	Client ContextClient // The source
	Key    string        // The query key, e.g. "domainConstraints"
}

// DefaultContextAggregator is a reference aggregator that simply merges 
// all retrieved context with a header or label. In real usage, you might 
// parse or chunk them further.
type DefaultContextAggregator struct {
	Label string // optional label for the aggregated context
}

// Aggregate calls each client with the given key, collecting results 
// into a single string.
func (dca *DefaultContextAggregator) Aggregate(ctx context.Context, items []ContextItem) (string, error) {
	var sb strings.Builder
	if dca.Label != "" {
		sb.WriteString(fmt.Sprintf("## %s\n", dca.Label))
	}

	for _, it := range items {
		text, err := it.Client.GetContext(ctx, it.Key)
		if err != nil {
			return "", fmt.Errorf("get context for key %q: %w", it.Key, err)
		}
		sb.WriteString(fmt.Sprintf("\n-- Context [%s] --\n", it.Key))
		sb.WriteString(text)
		sb.WriteString("\n")
	}

	return sb.String(), nil
}
