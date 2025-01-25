// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"fmt"
	"sort"
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
	systemMsg := `You are a Go expert. You will help modify or create Go code based on the user's request.

<structured_output>
{
  "name": "CodeChanges",
  "description": "Describes changes to make to the codebase",
  "format": "json",
  "fields": {
    "commit": {
      "type": "object",
      "description": "Information about the commit",
      "required": true,
      "fields": {
        "subject": {
          "type": "string",
          "description": "Short commit message (max 50 chars)",
          "required": true
        },
        "body": {
          "type": "string",
          "description": "Optional longer description",
          "required": false
        }
      }
    },
    "patches": {
      "type": "array",
      "description": "List of patches to apply",
      "required": true,
      "items": {
        "type": "object",
        "fields": {
          "file": {
            "type": "string",
            "description": "Path to the file to modify",
            "required": true
          },
          "type": {
            "type": "string",
            "description": "Type of change: create, replace, or delete",
            "enum": ["create", "replace", "delete"],
            "required": true
          },
          "fromLine": {
            "type": "integer",
            "description": "Starting line number (1-indexed)",
            "required": true
          },
          "toLine": {
            "type": "integer",
            "description": "Ending line number (1-indexed)",
            "required": true
          },
          "linesBefore": {
            "type": "array",
            "description": "Exactly 3 lines of code before the change",
            "items": {"type": "string"},
            "minItems": 3,
            "maxItems": 3,
            "required": true
          },
          "linesAfter": {
            "type": "array",
            "description": "Exactly 3 lines of code after the change",
            "items": {"type": "string"},
            "minItems": 3,
            "maxItems": 3,
            "required": true
          },
          "content": {
            "type": "string",
            "description": "New content with properly escaped special characters (tabs as \\t, newlines as \\n, quotes as \\\")",
            "required": true
          }
        }
      }
    }
  }
}
</structured_output>

IMPORTANT: 
1. Your response must be VALID JSON matching the above schema exactly
2. Make patches as minimal as possible, changing only necessary lines
3. Line numbers must match the actual code context provided
4. All code in content fields must properly escape special characters
5. If multiple changes are needed, include multiple patches in correct order
6. Verify line numbers and context match the actual code

Example response:
{
  "commit": {
    "subject": "Add new endpoint"
  },
  "patches": [{
    "file": "main.go",
    "type": "replace",
    "fromLine": 8,
    "toLine": 10,
    "linesBefore": ["package main", "", "import ("],
    "linesAfter": [")", "", "func createUser(w http.ResponseWriter, r *http.Request) {"],
    "content": "\t\"encoding/json\"\n\t\"fmt\"\n\t\"net/http\""
  }]
}
`
	rb.addContent(&b, systemMsg)

	// Add code context if within token limit
	if rb.codeCtx != nil {
		b.WriteString("\nCode to modify (VERIFY LINE NUMBERS CAREFULLY):\n")
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

	// Extract keywords from the prompt
	keywords := strings.Fields(strings.ToLower(prompt))

	// Score each file based on:
	// 1. Symbol matches (functions, types, etc)
	// 2. Content relevance
	// 3. References between files
	type scoredFile struct {
		path  string
		score int
	}
	var scoredFiles []scoredFile

	// Score files based on symbol matches
	for path, file := range rb.codeCtx.Files {
		score := 0

		// Check symbols in the file
		for _, symbol := range file.Symbols {
			symbolName := strings.ToLower(symbol.Name)
			for _, keyword := range keywords {
				if strings.Contains(symbolName, keyword) {
					score += 10 // Higher score for symbol matches
				}
			}

			// Check symbol documentation
			if symbol.DocString != "" {
				docLower := strings.ToLower(symbol.DocString)
				for _, keyword := range keywords {
					if strings.Contains(docLower, keyword) {
						score += 5 // Medium score for doc matches
					}
				}
			}

			// Check references to increase relevance of related files
			if symbol.References != nil {
				for _, ref := range symbol.References {
					if ref != nil && ref.URI != path {
						score += 2 // Small score for references
					}
				}
			}
		}

		// Check file content
		content := strings.ToLower(file.Content)
		for _, keyword := range keywords {
			if strings.Contains(content, keyword) {
				score++ // Small score for content matches
			}
		}

		if score > 0 {
			scoredFiles = append(scoredFiles, scoredFile{path: path, score: score})
		}
	}

	// Sort files by score
	sort.Slice(scoredFiles, func(i, j int) bool {
		return scoredFiles[i].score > scoredFiles[j].score
	})

	// Build context string with most relevant files
	var b strings.Builder
	maxFiles := 3 // Limit to top 3 most relevant files
	if len(scoredFiles) > maxFiles {
		scoredFiles = scoredFiles[:maxFiles]
	}

	for _, sf := range scoredFiles {
		file := rb.codeCtx.Files[sf.path]
		header := fmt.Sprintf("=== %s ===\n", sf.path)
		if !rb.addContent(&b, header) {
			break
		}

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
