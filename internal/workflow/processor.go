package workflow

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/patch"
)

// processor implements Processor interface
type processor struct {
	gitCommitter    GitCommitter
	validator       Validator
	reqBuilder      LLMRequestBuilder
	patchApplier    patch.Applier
	userInteraction UserInteraction
	llmClient       ai.LLMClient
}

// NewProcessor creates a new workflow processor with the given configuration
func NewProcessor(cfg *ProcessorConfig) (Processor, error) {
	if cfg == nil {
		return nil, fmt.Errorf("processor config is required")
	}

	return &processor{
		gitCommitter:    cfg.GitCommitter,
		validator:       cfg.Validator,
		reqBuilder:      cfg.RequestBuilder,
		patchApplier:    cfg.PatchApplier,
		userInteraction: cfg.UserInteraction,
		llmClient:       cfg.LLMClient,
	}, nil
}

// Process handles the workflow of processing a prompt through the LLM and applying changes
func (p *processor) Process(ctx context.Context, prompt string) error {
	for {
		// Build LLM request
		request := p.reqBuilder.Build(prompt)

		// Get patches from LLM
		patchJSON, err := p.llmClient.GetPatch(ctx, request)
		if err != nil {
			return fmt.Errorf("get patch from LLM: %w", err)
		}

		// Debug: Print the raw JSON response
		fmt.Printf("\nDebug - LLM Response:\n%s\n\n", patchJSON)

		// Parse patch set
		var ps patch.PatchSet
		if err := json.Unmarshal([]byte(patchJSON), &ps); err != nil {
			return fmt.Errorf("parse patch set: %w", err)
		}

		// Prompt user for changes
		mode, newPrompt, err := p.userInteraction.PromptForChanges(ctx, &ps)
		if err != nil {
			return fmt.Errorf("prompt for changes: %w", err)
		}

		switch mode {
		case ModeYes:
			return p.applyChanges(ctx, &ps)
		case ModeNo:
			return nil
		case ModeChat:
			if newPrompt == "" {
				return fmt.Errorf("new prompt is empty")
			}
			prompt = newPrompt
			continue
		case ModeAbort:
			return fmt.Errorf("operation aborted by user")
		case ModeAll:
			return p.applyChanges(ctx, &ps)
		case ModeYolo:
			return p.applyChanges(ctx, &ps)
		default:
			return fmt.Errorf("invalid mode: %v", mode)
		}
	}
}

// applyChanges applies the patch set and creates a commit
func (p *processor) applyChanges(ctx context.Context, ps *patch.PatchSet) error {
	// Apply patches
	if err := p.patchApplier.Apply(ps); err != nil {
		return fmt.Errorf("apply patches: %w", err)
	}

	// Run validation
	if err := p.validator.Validate(ctx); err != nil {
		return fmt.Errorf("validate changes: %w", err)
	}

	// Create commit
	commitMsg := ps.Commit.Subject
	if ps.Commit.Body != "" {
		commitMsg += "\n\n" + ps.Commit.Body
	}

	if err := p.gitCommitter.Commit(ctx, commitMsg); err != nil {
		return fmt.Errorf("create commit: %w", err)
	}

	return nil
}
