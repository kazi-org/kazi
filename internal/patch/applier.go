package patch

import (
	"context"
	"fmt"
)

// patchApplier implements the Applier interface
type patchApplier struct {
	validator  PatchValidator
	applier    PatchApplier
	rollbacker PatchRollbacker
}

// NewApplier creates a new patch applier for the given workspace
func NewApplier(workspace string) Applier {
	fm := NewFileManager(workspace)
	return &patchApplier{
		validator:  NewPatchValidator(fm),
		applier:    NewPatchApplier(fm),
		rollbacker: NewPatchRollbacker(fm),
	}
}

// Apply applies the patches to the workspace
func (pa *patchApplier) Apply(ps *PatchSet) error {
	ctx := context.Background()

	// First validate all patches
	for _, p := range ps.Patches {
		if err := pa.validator.Validate(ctx, p); err != nil {
			return fmt.Errorf("validate patch: %w", err)
		}
	}

	// Apply all patches
	for _, p := range ps.Patches {
		if err := pa.applier.Apply(ctx, p); err != nil {
			if rollbackErr := pa.rollbacker.Rollback(ctx); rollbackErr != nil {
				return fmt.Errorf("apply failed and rollback failed: %v (original error: %w)", rollbackErr, err)
			}
			return fmt.Errorf("apply patch: %w", err)
		}
	}

	return nil
}
