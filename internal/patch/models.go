package patch

// PatchType represents the type of patch operation
type PatchType string

const (
	PatchCreate  PatchType = "create"
	PatchReplace PatchType = "replace"
	PatchDelete  PatchType = "delete"
)

// Chunk represents a single patch operation
type Chunk struct {
	File          string    `json:"file"`
	Type          PatchType `json:"type"`
	FromLine      int       `json:"fromLine"`
	ToLine        int       `json:"toLine"`
	ContextBefore []string  `json:"contextBefore"`
	ContextAfter  []string  `json:"contextAfter"`
	Content       string    `json:"content"`
}

// CommitMessage represents a structured git commit message
type CommitMessage struct {
	Subject string `json:"subject"` // Short imperative summary (max 50 chars)
	Body    string `json:"body"`    // Detailed explanation (optional)
}

// PatchSet is the top-level object from the LLM
type PatchSet struct {
	Commit  CommitMessage `json:"commit"`
	Patches []Chunk       `json:"patches"`
}
