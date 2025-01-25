package patch

import (
	"context"
	"fmt"
	"sync"
)

// defaultApplier implements the Applier interface
type defaultApplier struct {
	validator PatchValidator
	applier   PatchApplier
	rollback  PatchRollbacker
	mu        sync.Mutex
}

// NewApplier creates a new patch applier for the given workspace
func NewApplier(workspace string) Applier {
	fm := NewFileManager(workspace)
	return NewApplierWithDeps(
		NewPatchValidator(fm),
		NewPatchApplier(fm),
		NewPatchRollbacker(fm),
	)
}

// NewApplierWithDeps creates a new patch applier with explicit dependencies
func NewApplierWithDeps(validator PatchValidator, applier PatchApplier, rollback PatchRollbacker) Applier {
	return &defaultApplier{
		validator: validator,
		applier:   applier,
		rollback:  rollback,
	}
}

// Apply applies a set of patches atomically, rolling back on failure
func (a *defaultApplier) Apply(ps *PatchSet) error {
	a.mu.Lock()
	defer a.mu.Unlock()

	ctx := context.Background()

	// First validate all patches
	for _, chunk := range ps.Patches {
		if err := a.validator.Validate(ctx, chunk); err != nil {
			return fmt.Errorf("validate patch for %s: %w", chunk.File, err)
		}
	}

	// Create backups for all files that will be modified
	for _, chunk := range ps.Patches {
		if chunk.Type != PatchCreate {
			if err := a.rollback.Backup(chunk.File, chunk.Type == PatchDelete); err != nil {
				return fmt.Errorf("backup file %s: %w", chunk.File, err)
			}
		}
	}

	// Apply all patches
	for _, chunk := range ps.Patches {
		if err := a.applier.Apply(ctx, chunk); err != nil {
			// If any patch fails, attempt to rollback
			if rbErr := a.rollback.Rollback(ctx); rbErr != nil {
				return fmt.Errorf("patch failed: %v; rollback failed: %v", err, rbErr)
			}
			return fmt.Errorf("apply patch to %s: %w", chunk.File, err)
		}
	}

	return nil
}
