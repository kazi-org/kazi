package workflow

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
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
func (p *processor) Process(ctx context.Context, prompt config.Prompt) error {
	for {
		// Build LLM request
		request := p.reqBuilder.Build(prompt)

		// Get patch from LLM
		resp, err := p.llmClient.GetPatch(ctx, request)
		if err != nil {
			return fmt.Errorf("get patch from LLM: %w", err)
		}

		// Parse patch set
		var ps patch.PatchSet
		if err := json.Unmarshal([]byte(resp), &ps); err != nil {
			return fmt.Errorf("parse patch JSON: %w", err)
		}

		// Get user's decision
		mode, newPrompt, err := p.userInteraction.PromptForChanges(ctx, &ps)
		if err != nil {
			return fmt.Errorf("get user decision: %w", err)
		}

		switch mode {
		case ModeYes:
			if err := p.applyChanges(ctx, &ps); err != nil {
				return err
			}
			return nil

		case ModeNo:
			return nil

		case ModeChat:
			if newPrompt == nil {
				return fmt.Errorf("chat mode requires a new prompt")
			}
			prompt = *newPrompt
			continue

		case ModeAbort:
			return nil

		case ModeAll:
			if err := p.applyChanges(ctx, &ps); err != nil {
				return err
			}
			return nil

		case ModeYolo:
			if err := p.applyChanges(ctx, &ps); err != nil {
				return err
			}
			return nil

		default:
			return fmt.Errorf("unknown interaction mode: %v", mode)
		}
	}
}

// applyChanges applies the patch set and commits the changes
func (p *processor) applyChanges(ctx context.Context, ps *patch.PatchSet) error {
	// Apply patches
	if err := p.patchApplier.Apply(ps); err != nil {
		return fmt.Errorf("apply patches: %w", err)
	}

	// Run build/test validation
	if err := p.validator.Validate(ctx); err != nil {
		return fmt.Errorf("validation failed: %w", err)
	}

	// Show diff and commit changes
	if err := p.commitChanges(ctx, ps); err != nil {
		return fmt.Errorf("commit changes: %w", err)
	}

	return nil
}

// commitChanges handles showing diff and committing changes
func (p *processor) commitChanges(ctx context.Context, ps *patch.PatchSet) error {
	// Get status
	status, err := p.gitCommitter.Status(ctx)
	if err != nil {
		return fmt.Errorf("get git status: %w", err)
	}

	if status.IsClean() {
		fmt.Println("No changes to commit.")
		return nil
	}

	fmt.Printf("Changes in workspace:\n%s\n\n", status.String())

	// Show commit message
	fmt.Printf("Proposed commit message:\n%s\n", ps.Commit.Subject)
	if ps.Commit.Body != "" {
		fmt.Printf("\n%s\n", ps.Commit.Body)
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
