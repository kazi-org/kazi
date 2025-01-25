package patch

import (
	"context"
	"io"
	"os"
)

// FileReader handles file reading operations
type FileReader interface {
	// ReadFile reads the content of a file at the given path
	// Returns ErrFileNotFound if the file doesn't exist
	ReadFile(path string) ([]byte, error)
}

// FileWriter handles file writing operations
type FileWriter interface {
	// WriteFile writes data to a file at the given path with specified permissions
	WriteFile(path string, data []byte, perm os.FileMode) error
}

// FileDeleter handles file deletion operations
type FileDeleter interface {
	// DeleteFile removes a file at the given path
	// Returns ErrFileNotFound if the file doesn't exist
	DeleteFile(path string) error
}

// DirCreator handles directory creation operations
type DirCreator interface {
	// CreateDir creates a directory and its parents if they don't exist
	CreateDir(path string, perm os.FileMode) error
}

// FileManager combines all file operation interfaces
type FileManager interface {
	FileReader
	FileWriter
	FileDeleter
	DirCreator
	io.Closer
}

// PatchValidator validates patch operations before applying them
type PatchValidator interface {
	// Validate checks if a patch can be applied to the workspace
	// Returns appropriate error types for different validation failures
	Validate(ctx context.Context, chunk Chunk) error
}

// PatchApplier applies validated patches to the workspace
type PatchApplier interface {
	// Apply applies a validated patch to the workspace
	// Returns appropriate error types for different application failures
	Apply(ctx context.Context, chunk Chunk) error
}

// BackupManager handles file backup operations
type BackupManager interface {
	// Backup creates a backup of a file before modification
	// The isDelete parameter indicates if the file will be deleted
	Backup(path string, isDelete bool) error
}

// RollbackManager handles rollback operations
type RollbackManager interface {
	// Rollback restores the workspace to its state before patch application
	// Returns a list of any errors encountered during rollback
	Rollback(ctx context.Context) error
}

// PatchRollbacker combines backup and rollback operations
type PatchRollbacker interface {
	BackupManager
	RollbackManager
}

// Applier is the main interface for applying patch sets
type Applier interface {
	// Apply applies the patches to the workspace atomically
	// If any patch fails, all changes are rolled back
	Apply(ps *PatchSet) error
}
