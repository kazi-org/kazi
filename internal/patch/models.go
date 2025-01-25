package patch

import "fmt"

// PatchType represents the type of patch operation to be performed
type PatchType string

const (
	// PatchCreate indicates a new file should be created
	PatchCreate PatchType = "create"
	// PatchReplace indicates existing content should be replaced
	PatchReplace PatchType = "replace"
	// PatchDelete indicates a file should be deleted
	PatchDelete PatchType = "delete"
)

// ErrInvalidPatchType indicates an unsupported patch type was specified
type ErrInvalidPatchType struct {
	Type PatchType
}

func (e ErrInvalidPatchType) Error() string {
	return fmt.Sprintf("invalid patch type: %s", e.Type)
}

// ErrFileExists indicates a file already exists when trying to create it
type ErrFileExists struct {
	Path string
}

func (e ErrFileExists) Error() string {
	return fmt.Sprintf("file already exists: %s", e.Path)
}

// ErrFileNotFound indicates a file does not exist when it should
type ErrFileNotFound struct {
	Path string
}

func (e ErrFileNotFound) Error() string {
	return fmt.Sprintf("file not found: %s", e.Path)
}

// Chunk represents a single patch operation with its associated metadata
type Chunk struct {
	File          string    `json:"file"`          // Path to the file being modified
	Type          PatchType `json:"type"`          // Type of patch operation
	FromLine      int       `json:"fromLine"`      // Starting line for replace operations (1-based)
	ToLine        int       `json:"toLine"`        // Ending line for replace operations (1-based)
	ContextBefore []string  `json:"contextBefore"` // Lines of context before the change
	ContextAfter  []string  `json:"contextAfter"`  // Lines of context after the change
	Content       string    `json:"content"`       // New content to be applied
}

// CommitMessage represents a structured git commit message
type CommitMessage struct {
	Subject string `json:"subject"` // Short imperative summary (max 50 chars)
	Body    string `json:"body"`    // Detailed explanation
}

// PatchSet represents a complete set of changes to be applied atomically
type PatchSet struct {
	Commit  CommitMessage `json:"commit"`  // Associated commit message
	Patches []Chunk       `json:"patches"` // List of patches to apply
}
