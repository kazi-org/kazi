package workflow

import (
	"fmt"
	"strings"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
)

// requestBuilder implements LLMRequestBuilder interface
type requestBuilder struct {
	rules   []string
	config  config.GlobalConfig
	context *contextstore.CodeContext
}

// newRequestBuilder creates a new requestBuilder instance
func newRequestBuilder(rules []string, config config.GlobalConfig, context *contextstore.CodeContext) *requestBuilder {
	return &requestBuilder{
		rules:   rules,
		config:  config,
		context: context,
	}
}

// Build creates a formatted request string for the LLM
func (rb *requestBuilder) Build(prompt config.Prompt) string {
	var b strings.Builder

	// Add project rules
	if len(rb.rules) > 0 {
		b.WriteString("Project Rules:\n")
		for _, rule := range rb.rules {
			fmt.Fprintf(&b, "- %s\n", rule)
		}
		b.WriteString("\n")
	}

	// Add project configuration
	b.WriteString("Project Configuration:\n")
	if rb.config.LintCommand != "" {
		fmt.Fprintf(&b, "- Lint Command: %s\n", rb.config.LintCommand)
	}
	if rb.config.TestCommand != "" {
		fmt.Fprintf(&b, "- Test Command: %s\n", rb.config.TestCommand)
	}
	b.WriteString("\n")

	// Add workspace context
	if rb.context != nil && len(rb.context.Files) > 0 {
		b.WriteString("Workspace Context:\n")
		for path, fc := range rb.context.Files {
			rb.writeFileContext(&b, path, fc)
		}
		b.WriteString("\n")
	}

	// Add user request
	b.WriteString("User Request:\n")
	b.WriteString(prompt.Instructions)

	return b.String()
}

// writeFileContext writes file context information to the builder
func (rb *requestBuilder) writeFileContext(b *strings.Builder, path string, fc *contextstore.FileContext) {
	fmt.Fprintf(b, "File: %s\n", path)
	if len(fc.Imports) > 0 {
		fmt.Fprintf(b, "Imports: %s\n", strings.Join(fc.Imports, ", "))
	}
	for name, sc := range fc.Symbols {
		fmt.Fprintf(b, "Symbol: %s (%s)\n", name, sc.Kind)
		if sc.DocString != "" {
			fmt.Fprintf(b, "Doc: %s\n", sc.DocString)
		}
	}
}
