package workflow

import (
	"context"
	"fmt"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
)

// ProcessPrompt processes a prompt using the workflow processor
func ProcessPrompt(p config.Prompt, g config.GlobalConfig, rules []string, ctx *contextstore.CodeContext, client ai.LLMClient, userInteraction UserInteraction) error {
	// Create options
	opts := &Options{
		Workspace: g.Workspace,
		Rules:     rules,
		Context:   ctx,
		Config:    g,
	}

	// Create dependencies
	gitCommitter, err := newGitCommitter(g.Workspace)
	if err != nil {
		return fmt.Errorf("create git committer: %w", err)
	}

	validator := newValidator(g)
	requestBuilder := newRequestBuilder(rules, g, ctx)
	patchApplier := patch.NewApplier(g.Workspace)

	// Create processor config
	cfg := &ProcessorConfig{
		GitCommitter:    gitCommitter,
		Validator:       validator,
		RequestBuilder:  requestBuilder,
		PatchApplier:    patchApplier,
		UserInteraction: userInteraction,
		LLMClient:       client,
		Options:         opts,
	}

	// Create and run processor
	processor, err := NewProcessor(cfg)
	if err != nil {
		return fmt.Errorf("create processor: %w", err)
	}

	return processor.Process(context.Background(), p)
}
