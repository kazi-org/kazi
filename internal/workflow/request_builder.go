// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"fmt"
	"strings"

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

	// Add system message
	b.WriteString("You are an expert Go developer who follows best practices and writes clean, maintainable code. Your task is to help modify or create Go code based on the user's request.\n\n")
	b.WriteString("Please respond with a JSON object containing patches to apply. The response should have:\n")
	b.WriteString("1. A commit message with:\n")
	b.WriteString("   - subject: Short imperative summary (max 50 chars)\n")
	b.WriteString("   - body: Detailed explanation (optional)\n\n")
	b.WriteString("2. An array of patches, where each patch has:\n")
	b.WriteString("   - file: the path to the file to modify or create\n")
	b.WriteString("   - type: one of:\n")
	b.WriteString("     - 'create': create a new file\n")
	b.WriteString("     - 'replace': modify an existing file\n")
	b.WriteString("     - 'delete': delete an existing file\n")
	b.WriteString("   - fromLine: (for 'replace' only) the 1-indexed line number where the modification starts\n")
	b.WriteString("   - toLine: (for 'replace' only) the 1-indexed line number where the modification ends\n")
	b.WriteString("   - contextBefore: (optional) lines of context before the change\n")
	b.WriteString("   - contextAfter: (optional) lines of context after the change\n")
	b.WriteString("   - content: the content to insert/replace\n\n")
	b.WriteString("Example response format:\n")
	b.WriteString(`{
  "commit": {
    "subject": "Add error handling to processData function",
    "body": "- Add error return value\n- Handle edge cases\n- Add error tests"
  },
  "patches": [
    {
      "file": "main.go",
      "type": "create",
      "content": "package main\n\nfunc main() {\n  // ...\n}\n"
    },
    {
      "file": "utils.go",
      "type": "replace",
      "fromLine": 10,
      "toLine": 15,
      "contextBefore": [
        "package utils",
        "",
        "import \"errors\""
      ],
      "content": "func processData(data []string) ([]string, error) {\n  if len(data) == 0 {\n    return nil, errors.New(\"empty data\")\n  }\n  // ...\n}\n",
      "contextAfter": [
        "",
        "func otherFunc() {",
        "  // ..."
      ]
    }
  ]
}` + "\n\n")

	// Add patching guidelines
	b.WriteString("When creating patches:\n")
	b.WriteString("1. For new files, use 'create' type and provide the complete file content\n")
	b.WriteString("2. For modifying files:\n")
	b.WriteString("   - Use 'replace' type with correct fromLine and toLine\n")
	b.WriteString("   - Include contextBefore/contextAfter to show surrounding code\n")
	b.WriteString("   - Ensure the content fits correctly at the specified location\n")
	b.WriteString("3. For deleting files, use 'delete' type (no content needed)\n")
	b.WriteString("4. Write clear commit messages:\n")
	b.WriteString("   - Subject line should be imperative and concise\n")
	b.WriteString("   - Body should explain the what and why of changes\n")
	b.WriteString("5. Ensure all necessary imports are included\n")
	b.WriteString("6. Maintain consistent formatting and style\n\n")

	// Add Go best practices
	b.WriteString("Follow these Go best practices:\n")
	b.WriteString("- Give each type a single, well-defined responsibility (Single Responsibility)\n")
	b.WriteString("- Extend behavior by adding new types or methods rather than modifying existing code (Open-Closed)\n")
	b.WriteString("- Ensure that substitutable types preserve intended behavior (Liskov Substitution)\n")
	b.WriteString("- Break larger interfaces into smaller, specialized ones (Interface Segregation)\n")
	b.WriteString("- Depend on abstractions, not concrete implementations (Dependency Inversion)\n")
	b.WriteString("- Prefer composition over inheritance to keep code simple and flexible\n")
	b.WriteString("- Share memory by communicating (use goroutines and channels) rather than communicating by sharing memory\n")
	b.WriteString("- Return errors explicitly and handle them consistently, avoiding exceptions\n")
	b.WriteString("- Keep packages small and focused; each should have a single, clear purpose\n")
	b.WriteString("- Document your code to clarify intent, especially for exported types and functions\n\n")

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
			b.WriteString(fmt.Sprintf("=== %s ===\n", path))
			// Add file content with line numbers
			if file.Content != "" {
				b.WriteString("Content:\n```go\n")
				lines := strings.Split(file.Content, "\n")
				for i, line := range lines {
					b.WriteString(fmt.Sprintf("%4d | %s\n", i+1, line))
				}
				b.WriteString("```\n\n")
			}
			// Add symbols with locations
			b.WriteString("Symbols:\n")
			for name, sym := range file.Symbols {
				b.WriteString(fmt.Sprintf("- %s: %s\n", name, sym.Signature))
				b.WriteString(fmt.Sprintf("  Kind: %s\n", sym.Kind))
				if sym.DocString != "" {
					b.WriteString(fmt.Sprintf("  Doc: %s\n", sym.DocString))
				}
				if sym.Location != nil {
					b.WriteString(fmt.Sprintf("  Location: lines %d-%d\n",
						sym.Location.Range.Start.Line+1,
						sym.Location.Range.End.Line+1))
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
