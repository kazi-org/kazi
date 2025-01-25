package workflow

import (
	"fmt"
	"strings"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
)

// RequestBuilder helps build context-aware requests for the AI.
type RequestBuilder struct {
	codeCtx *types.CodeContext
	rules   []string
	config  config.GlobalConfig
}

// NewRequestBuilder creates a new request builder with the given code context.
func NewRequestBuilder(codeCtx *types.CodeContext) *RequestBuilder {
	return &RequestBuilder{codeCtx: codeCtx}
}

// NewRequestBuilderWithConfig creates a new request builder with the given configuration.
func NewRequestBuilderWithConfig(codeCtx *types.CodeContext, rules []string, config config.GlobalConfig) *RequestBuilder {
	return &RequestBuilder{
		codeCtx: codeCtx,
		rules:   rules,
		config:  config,
	}
}

// BuildRequest builds a request string that includes relevant code context.
func (rb *RequestBuilder) BuildRequest(userPrompt string, codeSnippet string) string {
	var b strings.Builder

	// Add user prompt
	b.WriteString("# USER's request\n")
	b.WriteString(userPrompt + "\n\n")

	// Add code snippet if provided
	if codeSnippet != "" {
		b.WriteString("# Code snippet\n```go\n")
		b.WriteString(codeSnippet)
		b.WriteString("\n```\n\n")
	}

	// Add relevant context
	context := rb.findRelevantContext(codeSnippet, userPrompt)
	if context != "" {
		b.WriteString("# Relevant code context\n")
		b.WriteString(context)
	}

	return b.String()
}

// findRelevantContext finds code context relevant to the user's request.
func (rb *RequestBuilder) findRelevantContext(codeSnippet, userPrompt string) string {
	if rb.codeCtx == nil || rb.codeCtx.Files == nil {
		return ""
	}

	type snippetScore struct {
		fc    *types.FileContext
		score int
	}

	var allScores []snippetScore
	keywords := strings.Fields(strings.ToLower(userPrompt + " " + codeSnippet))

	// Score each file based on keyword matches
	for _, fc := range rb.codeCtx.Files {
		if fc == nil {
			continue
		}
		score := 0
		for _, kw := range keywords {
			if strings.Contains(strings.ToLower(fc.FilePath), kw) {
				score += 5
			}
			for _, sym := range fc.Symbols {
				if sym == nil {
					continue
				}
				if strings.Contains(strings.ToLower(sym.Name), kw) {
					score += 3
				}
				if strings.Contains(strings.ToLower(sym.DocString), kw) {
					score += 2
				}
			}
		}
		if score > 0 {
			allScores = append(allScores, snippetScore{fc: fc, score: score})
		}
	}

	// Sort by score
	for i := 0; i < len(allScores)-1; i++ {
		for j := i + 1; j < len(allScores); j++ {
			if allScores[i].score < allScores[j].score {
				allScores[i], allScores[j] = allScores[j], allScores[i]
			}
		}
	}

	// Build context string with top matches
	var b strings.Builder
	for i, scored := range allScores {
		if i >= 3 { // Limit to top 3 files
			break
		}
		fc := scored.fc
		b.WriteString(fmt.Sprintf("File: %s\n", fc.FilePath))
		if len(fc.Imports) > 0 {
			b.WriteString(fmt.Sprintf("Imports: %s\n", strings.Join(fc.Imports, ", ")))
		}
		for _, sym := range fc.Symbols {
			if sym == nil {
				continue
			}
			b.WriteString(fmt.Sprintf("Symbol: %s (%s)\n", sym.Name, sym.Kind))
			if sym.DocString != "" {
				b.WriteString("  " + sym.DocString + "\n")
			}
		}
		b.WriteString("\n")
	}

	return b.String()
}

// Build implements the LLMRequestBuilder interface.
func (rb *RequestBuilder) Build(prompt config.Prompt) string {
	var b strings.Builder

	// Add project rules if available
	if len(rb.rules) > 0 {
		b.WriteString("# Project Rules:\n")
		for _, rule := range rb.rules {
			b.WriteString("- " + rule + "\n")
		}
		b.WriteString("\n")
	}

	// Add project configuration
	b.WriteString("# Project Configuration:\n")
	b.WriteString("- Lint Command: " + rb.config.LintCommand + "\n")
	b.WriteString("- Test Command: " + rb.config.TestCommand + "\n\n")

	// Add user request
	b.WriteString("# User Request:\n")
	b.WriteString(prompt.Instructions + "\n\n")

	// Add code context
	if rb.codeCtx != nil && len(rb.codeCtx.Files) > 0 {
		b.WriteString("# Workspace Context:\n")
		for path, fc := range rb.codeCtx.Files {
			if fc == nil {
				continue
			}
			b.WriteString(fmt.Sprintf("File: %s\n", path))
			if len(fc.Imports) > 0 {
				b.WriteString(fmt.Sprintf("Imports: %s\n", strings.Join(fc.Imports, ", ")))
			}
			for name, sym := range fc.Symbols {
				if sym == nil {
					continue
				}
				b.WriteString(fmt.Sprintf("Symbol: %s (%s)\n", name, sym.Kind))
				if sym.DocString != "" {
					b.WriteString("  " + sym.DocString + "\n")
				}
			}
			b.WriteString("\n")
		}
	}

	return b.String()
}
