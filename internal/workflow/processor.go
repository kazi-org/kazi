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
	llmClient    ai.LLMClient
	gitCommitter GitCommitter
	validator    Validator
	reqBuilder   LLMRequestBuilder
	patchApplier patch.Applier
}

// NewProcessor creates a new workflow processor with the given configuration
func NewProcessor(llmClient ai.LLMClient, cfg *ProcessorConfig) (Processor, error) {
	if cfg == nil {
		return nil, fmt.Errorf("processor config is required")
	}

	return &processor{
		llmClient:    llmClient,
		gitCommitter: cfg.GitCommitter,
		validator:    cfg.Validator,
		reqBuilder:   cfg.RequestBuilder,
		patchApplier: cfg.PatchApplier,
	}, nil
}

// Process handles the workflow of processing a prompt through the LLM and applying changes
func (p *processor) Process(ctx context.Context, prompt config.Prompt) error {
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

	// Apply patches
	if err := p.patchApplier.Apply(&ps); err != nil {
		return fmt.Errorf("apply patches: %w", err)
	}

	// Run build/test validation
	if err := p.validator.Validate(ctx); err != nil {
		return fmt.Errorf("validation failed: %w", err)
	}

	// Show diff and commit changes
	if err := p.commitChanges(ctx, prompt, &ps); err != nil {
		return fmt.Errorf("commit changes: %w", err)
	}

	return nil
}

// commitChanges handles showing diff and committing changes
func (p *processor) commitChanges(ctx context.Context, prompt config.Prompt, ps *patch.PatchSet) error {
	// Get status
	status, err := p.gitCommitter.Status(ctx)
	if err != nil {
		return fmt.Errorf("get git status: %w", err)
	}

	fmt.Printf("\n--- Processing prompt: %s ---\n\n", prompt.Name)

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
