package workflow

import (
	"context"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
)

// ProcessPrompt processes a prompt using the workflow processor
func ProcessPrompt(p config.Prompt, g config.GlobalConfig, rules []string, ctx *contextstore.CodeContext, client ai.LLMClient) error {
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
		return err
	}

	validator := newValidator(g)
	requestBuilder := newRequestBuilder(rules, g, ctx)
	patchApplier := patch.NewApplier(g.Workspace)

	// Create processor config
	cfg := &ProcessorConfig{
		GitCommitter:   gitCommitter,
		Validator:      validator,
		RequestBuilder: requestBuilder,
		PatchApplier:   patchApplier,
		Options:        opts,
	}

	// Create and run processor
	processor, err := NewProcessor(client, cfg)
	if err != nil {
		return err
	}

	return processor.Process(context.Background(), p)
}
