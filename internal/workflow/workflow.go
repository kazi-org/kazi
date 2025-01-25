// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/ai/openai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	"github.com/kazi-org/kazi/internal/patch"
)

// workflow implements request processing.
type workflow struct {
	codeCtx *types.CodeContext
	rules   []string
	config  config.GlobalConfig
	ai      ai.LLMClient
}

// NewWorkflow creates a new workflow.
func NewWorkflow(codeCtx *types.CodeContext, rules []string, config config.GlobalConfig) (*workflow, error) {
	// Initialize OpenAI client
	client, err := openai.NewClient()
	if err != nil {
		return nil, fmt.Errorf("create OpenAI client: %w", err)
	}

	return &workflow{
		codeCtx: codeCtx,
		rules:   rules,
		config:  config,
		ai:      client,
	}, nil
}

// Execute executes the workflow with the given prompt.
func (w *workflow) Execute(ctx context.Context, prompt string) (string, error) {
	// Create request builder with configuration
	rb := NewRequestBuilderWithConfig(w.codeCtx, w.rules, NewConfigFromGlobal(w.config, w.rules))

	// Build the request
	request := rb.BuildRequest(prompt)

	// Process through AI
	response, err := w.ai.GetPatch(ctx, request)
	if err != nil {
		return "", err
	}

	// Try to parse as JSON
	var ps patch.PatchSet
	if err := json.Unmarshal([]byte(response), &ps); err != nil {
		// Print the full response if JSON parsing fails
		fmt.Printf("\n=== Invalid JSON Response ===\n%s\n=== End Response ===\n\n", response)
		return "", fmt.Errorf("invalid JSON response: %w", err)
	}

	return response, nil
}

// Process processes a prompt with the given code context.
func Process(ctx context.Context, codeCtx *types.CodeContext, prompt string, rules []string, g config.GlobalConfig) (string, error) {
	// Create workflow
	w, err := NewWorkflow(codeCtx, rules, g)
	if err != nil {
		return "", fmt.Errorf("create workflow: %w", err)
	}

	// Execute workflow
	return w.Execute(ctx, prompt)
}
