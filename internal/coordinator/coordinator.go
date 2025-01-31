// internal/coordinator/coordinator.go
//
// Package coordinator orchestrates the prompt -> patch -> validation loop.
// It bridges the user’s intent with the underlying system components, including
// the Vision Contract, Architecture Manager, Patch Applier, and Validation Pipeline.
package coordinator

import (
	"github.com/kazi-org/kazi/internal/architecture"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/validation"
	"github.com/kazi-org/kazi/internal/vision"
)

// Coordinator defines the core interface for running code-generation cycles.
type Coordinator interface {
	// ProcessPrompt handles the user prompt by:
	// 1. Gathering context from the Vision Contract and Architecture.
	// 2. Calling the LLM to generate a patch.
	// 3. Applying the patch.
	// 4. Running validations.
	// 5. Committing or reverting changes.
	ProcessPrompt(prompt string) error
}

// DefaultCoordinator is a reference implementation of the Coordinator interface.
// It composes a Vision Contract, an Architecture Manager, a Patch Applier, and a Validation Pipeline.
type DefaultCoordinator struct {
	Contract            *vision.Contract
	ArchitectureManager architecture.Manager
	PatchApplier        patch.Applier
	Validator           validation.Pipeline
	// Additional fields (e.g., LLM client, knowledge store) can be added here.
}

// ProcessPrompt orchestrates the workflow for processing a user prompt.
func (dc *DefaultCoordinator) ProcessPrompt(prompt string) error {
	// TODO: Implement the workflow:
	// 1. Retrieve context (Vision Contract + Architecture).
	// 2. Call the LLM to produce a patch.
	// 3. Apply the patch.
	// 4. Validate changes.
	// 5. Commit or revert based on validation.
	return nil
}
