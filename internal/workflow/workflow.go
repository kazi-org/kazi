package workflow

import (
	"context"
	"fmt"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	"github.com/kazi-org/kazi/internal/patch"
)

// ProcessPrompt processes a prompt using the workflow processor
func ProcessPrompt(p config.Prompt, g config.GlobalConfig, rules []string, ctx *types.CodeContext, client ai.LLMClient, userInteraction UserInteraction) error {
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
	rb := NewRequestBuilderWithConfig(ctx, rules, g)
	patchApplier := patch.NewApplier(g.Workspace)

	// Create processor config
	cfg := &ProcessorConfig{
		GitCommitter:    gitCommitter,
		Validator:       validator,
		RequestBuilder:  rb,
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

// NewWorkflow creates a new workflow with the given configuration.
func NewWorkflow(config WorkflowConfig) Workflow {
	return &workflow{
		rules:     config.Rules,
		config:    config.Config,
		store:     config.Store,
		llmClient: config.LLMClient,
	}
}

// workflow implements the Workflow interface.
type workflow struct {
	rules     []string
	config    config.GlobalConfig
	store     ContextStore
	llmClient LLMClient
}

// Execute runs the workflow with the given context.
func (w *workflow) Execute(ctx context.Context) error {
	// Build or refresh code context
	if err := w.store.BuildOrRefresh(ctx); err != nil {
		return fmt.Errorf("failed to build code context: %w", err)
	}

	// Get current code context
	codeCtx := w.store.GetCodeContext()
	if codeCtx == nil {
		return fmt.Errorf("failed to get code context")
	}

	// Build request for LLM
	builder := NewRequestBuilderWithConfig(codeCtx, w.rules, w.config)
	request := builder.BuildRequest("", "") // TODO: Add actual prompt and code snippet

	// Get patches from LLM
	patches, err := w.llmClient.GetPatch(ctx, request)
	if err != nil {
		return fmt.Errorf("failed to get patches: %w", err)
	}

	// TODO: Process patches and apply changes
	_ = patches // Temporarily silence unused variable warning
	return nil
}
