package patch

import (
	"context"
	"os"
)

// PatchValidator validates patch operations before applying them
type PatchValidator interface {
	// Validate checks if a patch can be applied to the workspace
	Validate(ctx context.Context, chunk Chunk) error
}

// PatchApplier applies validated patches to the workspace
type PatchApplier interface {
	// Apply applies a validated patch to the workspace
	Apply(ctx context.Context, chunk Chunk) error
}

// PatchRollbacker handles rollback operations when patch application fails
type PatchRollbacker interface {
	// Rollback restores the workspace to its state before patch application
	Rollback(ctx context.Context) error
	// Backup stores a backup of a file before modification
	Backup(path string, isDelete bool) error
}

// FileManager handles file operations for patches
type FileManager interface {
	// ReadFile reads the content of a file
	ReadFile(path string) ([]byte, error)
	// WriteFile writes content to a file
	WriteFile(path string, data []byte, perm os.FileMode) error
	// DeleteFile deletes a file
	DeleteFile(path string) error
	// CreateDir creates a directory and its parents if they don't exist
	CreateDir(path string, perm os.FileMode) error
}

// Applier is the main interface for applying patch sets
type Applier interface {
	// Apply applies the patches to the workspace
	Apply(ps *PatchSet) error
}
