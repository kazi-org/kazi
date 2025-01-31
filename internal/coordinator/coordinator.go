// Package coordinator provides a single interface that orchestrates
// the entire workflow from user prompt to final validated code changes.

package coordinator

import (
	"github.com/yourorg/kazi/internal/patch"
	"github.com/yourorg/kazi/internal/project"
	"github.com/yourorg/kazi/internal/validation"
)

// Coordinator orchestrates the prompt -> LLM -> patch -> validation loop.
type Coordinator interface {
	// ProcessPrompt is the main workflow:
	//  1. Load/Update project context
	//  2. Generate a patch from the LLM
	//  3. Apply the patch
	//  4. Validate
	//  5. Commit or revert
	ProcessPrompt(prompt string) error
}

// DefaultCoordinator is a reference implementation that composes
// a Project Manager, Patch Applier, and Validation Pipeline.
// We also may reference an LSP client or knowledge logs if needed.
type DefaultCoordinator struct {
	ProjectManager project.Manager
	PatchApplier   patch.Applier
	Validator      validation.Pipeline
	// Possibly: LLM client, doc store, ephemeral logs, etc.
}

// ProcessPrompt is a stub to illustrate how you'd orchestrate the workflow.
func (dc *DefaultCoordinator) ProcessPrompt(prompt string) error {
	// 1. Retrieve or update the project (dc.ProjectManager.LoadProject(...) if needed)
	// 2. Possibly retrieve code chunks via ProvideChunks(...)
	// 3. Call LLM with the project + chunk info => get patch
	// 4. dc.PatchApplier.Apply(patchSet)
	// 5. dc.Validator.ValidateAll()
	// 6. If success, commit or finalize. If fail, revert or ask user.
	return nil
}
