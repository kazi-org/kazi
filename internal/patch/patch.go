package patch

import (
	"fmt"
	"os"
	"strings"
)

type PatchType string

const (
	PatchCreate  PatchType = "create"
	PatchReplace PatchType = "replace"
	PatchDelete  PatchType = "delete"
)

type Chunk struct {
	File          string    `json:"file"`
	Type          PatchType `json:"type"`
	FromLine      int       `json:"fromLine"`
	ToLine        int       `json:"toLine"`
	ContextBefore []string  `json:"contextBefore,omitempty"`
	ContextAfter  []string  `json:"contextAfter,omitempty"`
	Content       string    `json:"content"`
}

// PatchSet is the top-level object from the LLM
type PatchSet struct {
	Patches []Chunk `json:"patches"`
}

// Apply attempts to apply each chunk to the local workspace
func (ps *PatchSet) Apply(workspace string) error {
	for _, c := range ps.Patches {
		if err := applyChunk(c, workspace); err != nil {
			return fmt.Errorf("apply chunk in %s: %v", c.File, err)
		}
	}
	return nil
}

func applyChunk(c Chunk, workspace string) error {
	path := workspace + "/" + c.File
	switch c.Type {
	case PatchCreate:
		return os.WriteFile(path, []byte(c.Content), 0644)
	case PatchReplace:
		data, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read file for replace: %v", err)
		}
		lines := strings.Split(string(data), "\n")
		if c.FromLine <= 0 || c.ToLine > len(lines) {
			return fmt.Errorf("line range out of bounds, file has %d lines", len(lines))
		}
		// Insert c.Content lines in place
		newContent := make([]string, 0, len(lines))
		newContent = append(newContent, lines[:c.FromLine-1]...)
		newContent = append(newContent, strings.Split(c.Content, "\n")...)
		newContent = append(newContent, lines[c.ToLine:]...)
		final := strings.Join(newContent, "\n")
		return os.WriteFile(path, []byte(final), 0644)
	case PatchDelete:
		data, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read file for delete: %v", err)
		}
		lines := strings.Split(string(data), "\n")
		if c.FromLine <= 0 || c.ToLine > len(lines) {
			return fmt.Errorf("line range out of bounds, file has %d lines", len(lines))
		}
		newContent := make([]string, 0, len(lines))
		newContent = append(newContent, lines[:c.FromLine-1]...)
		newContent = append(newContent, lines[c.ToLine:]...)
		final := strings.Join(newContent, "\n")
		return os.WriteFile(path, []byte(final), 0644)
	default:
		return fmt.Errorf("unknown patch type: %s", c.Type)
	}
}
