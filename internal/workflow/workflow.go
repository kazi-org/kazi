// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"context"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
)

// workflow implements request processing.
type workflow struct {
	codeCtx *types.CodeContext
	rules   []string
	config  config.GlobalConfig
}

// NewWorkflow creates a new workflow.
func NewWorkflow(codeCtx *types.CodeContext, rules []string, config config.GlobalConfig) *workflow {
	return &workflow{
		codeCtx: codeCtx,
		rules:   rules,
		config:  config,
	}
}

// Execute executes the workflow with the given prompt.
func (w *workflow) Execute(ctx context.Context, prompt config.Prompt) (string, error) {
	// Create request builder with configuration
	rb := NewRequestBuilderWithConfig(w.codeCtx, w.rules, NewConfigFromGlobal(w.config, w.rules))

	// Build and return the request
	return rb.Build(prompt), nil
}

// Process processes a prompt with the given code context.
func Process(ctx context.Context, codeCtx *types.CodeContext, prompt config.Prompt, rules []string, g config.GlobalConfig) (string, error) {
	// Create workflow
	w := NewWorkflow(codeCtx, rules, g)

	// Execute workflow
	return w.Execute(ctx, prompt)
}
