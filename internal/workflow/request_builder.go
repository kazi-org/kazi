// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/kazi-org/kazi/internal/contextstore/types"
)

// RequestBuilder builds AI requests with code context.
type RequestBuilder struct {
	codeCtx    *types.CodeContext
	rules      []string
	config     *Config
	tokenCount int
}

// estimateTokens estimates the number of tokens in a string.
// This is a rough approximation based on GPT tokenization rules.
func (rb *RequestBuilder) estimateTokens(s string) int {
	// Rough approximation:
	// - 1 token per word (split by whitespace)
	// - 1 token per punctuation
	// - 1 token per 4 characters for non-word content
	words := strings.Fields(s)
	wordTokens := len(words)

	// Count punctuation and special characters
	punctCount := 0
	for _, r := range s {
		if strings.ContainsRune(".,!?;:()[]{}\"'", r) {
			punctCount++
		}
	}

	// Count remaining characters and divide by 4
	totalChars := utf8.RuneCountInString(s)
	wordChars := 0
	for _, word := range words {
		wordChars += utf8.RuneCountInString(word)
	}
	remainingChars := totalChars - wordChars - punctCount
	charTokens := remainingChars / 4

	return wordTokens + punctCount + charTokens
}

// addContent adds content to the builder if within token limit
func (rb *RequestBuilder) addContent(b *strings.Builder, content string) bool {
	tokens := rb.estimateTokens(content)
	if rb.config.Global.TokenLimit > 0 && rb.tokenCount+tokens > rb.config.Global.TokenLimit {
		return false
	}
	b.WriteString(content)
	rb.tokenCount += tokens
	return true
}

// BuildRequest builds an AI request with relevant code context.
func (rb *RequestBuilder) BuildRequest(prompt string) string {
	var b strings.Builder
	rb.tokenCount = 0

	// Add system message
	systemMsg := "You are a Go expert. CRITICAL: Respond ONLY with a SINGLE LINE of valid JSON matching this schema. Make patches as minimal as possible, changing only the lines that need to change. ALWAYS include 3 lines of context before and after the change:\n\n"
	rb.addContent(&b, systemMsg)

	// JSON schema
	schema := `{
  "commit": {
    "subject": "string (max 50 chars)",
    "body": "string (optional)"
  },
  "patches": [{
    "file": "string (file path)",
    "type": "create|replace|delete",
    "fromLine": "number (1-indexed, required for replace, ONLY include lines that actually change)",
    "toLine": "number (1-indexed, required for replace, ONLY include lines that actually change)",
    "contextBefore": ["string (REQUIRED, exactly 3 lines of context before the change)"],
    "contextAfter": ["string (REQUIRED, exactly 3 lines of context after the change)"],
    "content": "string (required for create/replace, ONLY include changed lines)"
  }]
}` + "\n\n"
	rb.addContent(&b, schema)

	// Example
	example := `Example (EXACTLY like this): {"commit":{"subject":"Optimize helloHandler"},"patches":[{"file":"main.go","type":"replace","fromLine":9,"toLine":9,"contextBefore":["import (",")","\nfunc helloHandler(w http.ResponseWriter, r *http.Request) {"],"contextAfter":["}","\nfunc main() {","\thttp.HandleFunc(\"/\", helloHandler)"],"content":"\tw.Write([]byte(\"Hello, World!\"))"}]}` + "\n\n"
	rb.addContent(&b, example)

	// Add code context if within token limit
	if rb.codeCtx != nil {
		b.WriteString("\nCode to modify:\n")
		for path, file := range rb.codeCtx.Files {
			header := fmt.Sprintf("=== %s ===\n", path)
			if !rb.addContent(&b, header) {
				break
			}

			// Add file content with line numbers if within token limit
			if file.Content != "" {
				if !rb.addContent(&b, "```go\n") {
					break
				}
				lines := strings.Split(file.Content, "\n")
				for i, line := range lines {
					lineContent := fmt.Sprintf("%4d | %s\n", i+1, line)
					if !rb.addContent(&b, lineContent) {
						rb.addContent(&b, "... (truncated)\n")
						break
					}
				}
				rb.addContent(&b, "```\n\n")
			}
		}
	}

	// Add rules if within token limit
	if len(rb.rules) > 0 {
		b.WriteString("\nFollow these rules:\n")
		for _, rule := range rb.rules {
			if !rb.addContent(&b, fmt.Sprintf("- %s\n", rule)) {
				break
			}
		}
		rb.addContent(&b, "\n")
	}

	// Always add the prompt
	rb.addContent(&b, "\nTask:\n")
	rb.addContent(&b, prompt)
	rb.addContent(&b, "\n\nRespond ONLY with the JSON. No explanation, no markdown.")

	return b.String()
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

// NewRequestBuilderWithConfig creates a new request builder with configuration.
func NewRequestBuilderWithConfig(codeCtx *types.CodeContext, rules []string, config *Config) *RequestBuilder {
	return &RequestBuilder{
		codeCtx:    codeCtx,
		rules:      rules,
		config:     config,
		tokenCount: 0,
	}
}

// Build implements the LLMRequestBuilder interface
func (rb *RequestBuilder) Build(prompt string) string {
	return rb.BuildRequest(prompt)
}
