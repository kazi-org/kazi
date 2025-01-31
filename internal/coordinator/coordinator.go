// coordinator.go
//
// Defines the Coordinator interface plus a simplified but more powerful 
// DefaultCoordinator that uses the ContextAggregator + LLMClient + patch + validation.

package coordinator

import (
	"context"
	"fmt"

	"github.com/yourorg/kazi/internal/patch"
	"github.com/yourorg/kazi/internal/validation"
)

// Coordinator orchestrates prompt -> gather context -> LLM -> patch -> validation -> finalize.
type Coordinator interface {
	// ProcessPrompt is the main entry. It gathers context from various sources,
	// calls the LLM, applies patches, runs validation, and finalizes changes.
	ProcessPrompt(ctx context.Context, userPrompt string) error
}

// DefaultCoordinator composes everything needed for a typical Kazi workflow.
type DefaultCoordinator struct {
	// We standardize how we gather context from multiple sources 
	// by referencing a ContextAggregator.
	ContextAggregator ContextAggregator

	// We also rely on an LLMClient to produce patches from the final prompt.
	LLMClient LLMClient

	// Applier for the patch
	PatchApplier patch.Applier

	// Validation pipeline
	Validator validation.Pipeline

	// We can define which context items or keys to gather each time. 
	// For instance, "domainConstraints", "docs/productContext", "ephemeralLog".
	ContextItems []ContextItem
}

// ProcessPrompt orchestrates the entire loop in a simplified but more powerful approach.
func (dc *DefaultCoordinator) ProcessPrompt(ctx context.Context, userPrompt string) error {
	if dc.ContextAggregator == nil {
		return fmt.Errorf("nil ContextAggregator in coordinator")
	}
	if dc.LLMClient == nil {
		return fmt.Errorf("nil LLMClient in coordinator")
	}
	if dc.PatchApplier == nil {
		return fmt.Errorf("nil PatchApplier")
	}
	if dc.Validator == nil {
		return fmt.Errorf("nil Validator")
	}

	// 1. Gather all contexts from various sources
	contextStr, err := dc.ContextAggregator.Aggregate(ctx, dc.ContextItems)
	if err != nil {
		return fmt.Errorf("aggregate context: %w", err)
	}

	// 2. Build a final prompt by merging the user's prompt with the aggregated contexts
	finalPrompt := fmt.Sprintf("User Task:\n%s\n\nAdditional Context:\n%s", userPrompt, contextStr)

	// 3. Call the LLM to get a patch
	ps, err := dc.LLMClient.GeneratePatch(ctx, finalPrompt)
	if err != nil {
		return fmt.Errorf("generate patch: %w", err)
	}
	if ps == nil {
		return fmt.Errorf("LLM returned nil PatchSet")
	}

	// 4. Apply the patch
	if err := dc.PatchApplier.Apply(ctx, ps); err != nil {
		return fmt.Errorf("apply patch: %w", err)
	}

	// 5. Validate the newly patched code
	res := dc.Validator.ValidateAll(ctx)
	if !res.Success {
		return fmt.Errorf("validation failed:\n%v", res.Error())
	}

	// 6. If we get here, all is well. We might finalize or commit changes
	fmt.Println("All done! Patch applied and validated successfully.")
	return nil
}
