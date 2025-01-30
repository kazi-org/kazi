// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/ai/openai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	"github.com/kazi-org/kazi/internal/log"
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
	log.Debug("Creating new workflow with %d rules", len(rules))

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
	log.Debug("Executing workflow with prompt: %s", prompt)

	// Create request builder with configuration
	rb := NewRequestBuilderWithConfig(w.codeCtx, w.rules, NewConfigFromGlobal(w.config, w.rules))

	// Build the request
	request := rb.BuildRequest(prompt)
	log.Debug("Built request with %d tokens", rb.TokenCount())
	log.Debug("\n=== LLM Request ===\n%s\n=== End Request ===\n", request)

	// Process through AI
	log.Debug("Sending request to AI")
	response, err := w.ai.GetPatch(ctx, request)
	log.Debug("\n=== LLM Response ===\n%s\n=== End Response ===\n", response)
	if err != nil {
		return "", err
	}

	// Try to parse as JSON
	var ps patch.PatchSet
	if err := json.Unmarshal([]byte(response), &ps); err != nil {
		// Print the full response if JSON parsing fails
		log.Error("Invalid JSON response:\n%s", response)
		return "", fmt.Errorf("invalid JSON response: %w", err)
	}
	log.Debug("Successfully parsed response with %d patches", len(ps.Patches))

	return response, nil
}

// Process processes a prompt with the given code context.
func Process(ctx context.Context, codeCtx *types.CodeContext, prompt string, rules []string, g config.GlobalConfig) (string, error) {
	log.Debug("Processing prompt with %d rules", len(rules))
	if codeCtx != nil {
		log.Debug("Code context contains %d files:", len(codeCtx.Files))
		for path, file := range codeCtx.Files {
			log.Debug("  - %s (%d lines)", path, len(strings.Split(file.Content, "\n")))
			log.Debug("    Symbols: %d", len(file.Symbols))
			for _, symbol := range file.Symbols {
				log.Debug("      - %s (%s)", symbol.Name, symbol.Kind)
			}
		}
	} else {
		log.Debug("No code context provided")
	}

	// Create workflow
	w, err := NewWorkflow(codeCtx, rules, g)
	if err != nil {
		return "", fmt.Errorf("create workflow: %w", err)
	}

	// Execute workflow
	return w.Execute(ctx, prompt)
}
