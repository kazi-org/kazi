// Package coordinator orchestrates the prompt -> patch -> validation loop.

package coordinator

import (
	"github.com/yourorg/kazi/internal/architecture"
	"github.com/yourorg/kazi/internal/patch"
	"github.com/yourorg/kazi/internal/validation"
	"github.com/yourorg/kazi/internal/vision"
)

// Coordinator is the core interface for running code-generation cycles.
type Coordinator interface {
	// ProcessPrompt handles the user prompt, fetches relevant code from the architecture,
	// calls the LLM, applies patches, runs validation, commits changes if successful, etc.
	ProcessPrompt(prompt string) error
}

// DefaultCoordinator is a reference implementation that composes
// the Vision Contract, Architecture Manager, Patch Applier, and Validator.
type DefaultCoordinator struct {
	Contract            *vision.Contract
	ArchitectureManager architecture.Manager
	PatchApplier        patch.Applier
	Validator           validation.Pipeline
	// Possibly references to knowledge.Store, LLM client, etc.
}

// ProcessPrompt is a stub method to illustrate how you'd orchestrate the workflow.
func (dc *DefaultCoordinator) ProcessPrompt(prompt string) error {
	// 1. Gather context from Vision Contract + architecture
	// 2. Call LLM to produce a patch
	// 3. Apply patch with dc.PatchApplier.Apply(patchSet)
	// 4. Run dc.Validator.ValidateAll()
	// 5. Commit or revert changes
	return nil
}
