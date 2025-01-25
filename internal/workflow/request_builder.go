// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"fmt"
	"strings"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
)

// RequestBuilder builds AI requests with code context.
type RequestBuilder struct {
	codeCtx *types.CodeContext
	rules   []string
	config  *Config
}

// NewRequestBuilderWithConfig creates a new request builder with configuration.
func NewRequestBuilderWithConfig(codeCtx *types.CodeContext, rules []string, config *Config) *RequestBuilder {
	return &RequestBuilder{
		codeCtx: codeCtx,
		rules:   rules,
		config:  config,
	}
}

// BuildRequest builds an AI request with relevant code context.
func (rb *RequestBuilder) BuildRequest(prompt string) string {
	var b strings.Builder

	// Add global configuration
	if rb.config != nil && rb.config.Global.Rules != nil {
		b.WriteString("Global rules:\n")
		for _, rule := range rb.config.Global.Rules {
			b.WriteString(fmt.Sprintf("- %s\n", rule))
		}
		b.WriteString("\n")
	}

	// Add specific rules
	if len(rb.rules) > 0 {
		b.WriteString("Specific rules:\n")
		for _, rule := range rb.rules {
			b.WriteString(fmt.Sprintf("- %s\n", rule))
		}
		b.WriteString("\n")
	}

	// Add code context
	if rb.codeCtx != nil {
		b.WriteString("Code context:\n")
		for path, file := range rb.codeCtx.Files {
			b.WriteString(fmt.Sprintf("%s:\n", path))
			for name, sym := range file.Symbols {
				b.WriteString(fmt.Sprintf("- %s: %s\n", name, sym.Signature))
				b.WriteString(fmt.Sprintf("  Kind: %s\n", sym.Kind))
				if sym.DocString != "" {
					b.WriteString(fmt.Sprintf("  Doc: %s\n", sym.DocString))
				}
			}
			b.WriteString("\n")
		}
	}

	// Add the prompt
	b.WriteString("Instructions:\n")
	b.WriteString(prompt)

	return b.String()
}

// Build implements the LLMRequestBuilder interface.
func (rb *RequestBuilder) Build(prompt config.Prompt) string {
	return rb.BuildRequest(prompt.Instructions)
}

// findRelevantContext finds code context relevant to the prompt.
func (rb *RequestBuilder) findRelevantContext(prompt string) string {
	if rb.codeCtx == nil {
		return ""
	}

	type scoredSymbol struct {
		symbol *types.SymbolContext
		score  int
	}

	var scored []scoredSymbol
	keywords := strings.Fields(strings.ToLower(prompt))

	// Score each symbol based on keyword matches
	for _, file := range rb.codeCtx.Files {
		for _, sym := range file.Symbols {
			score := 0

			// Check symbol name
			for _, kw := range keywords {
				if strings.Contains(strings.ToLower(sym.Name), kw) {
					score += 5
				}
				if strings.Contains(strings.ToLower(sym.DocString), kw) {
					score += 3
				}
				if strings.Contains(strings.ToLower(sym.Signature), kw) {
					score += 2
				}
			}

			if score > 0 {
				scored = append(scored, scoredSymbol{symbol: sym, score: score})
			}
		}
	}

	// Sort by score in descending order
	for i := 0; i < len(scored)-1; i++ {
		for j := i + 1; j < len(scored); j++ {
			if scored[j].score > scored[i].score {
				scored[i], scored[j] = scored[j], scored[i]
			}
		}
	}

	// Build context string with top matches
	var b strings.Builder
	for i, s := range scored {
		if i >= 5 { // Limit to top 5 matches
			break
		}

		sym := s.symbol
		b.WriteString(fmt.Sprintf("=== %s (%s) ===\n", sym.Name, sym.Kind))
		if sym.DocString != "" {
			b.WriteString(sym.DocString + "\n")
		}
		if sym.Signature != "" {
			b.WriteString(sym.Signature + "\n")
		}
		b.WriteString("\n")
	}

	return b.String()
}
