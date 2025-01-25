package patch

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

// Apply attempts to apply each chunk to the local workspace
func (ps *PatchSet) Apply(workspace string) error {
	for _, p := range ps.Patches {
		path := filepath.Join(workspace, p.File)

		switch p.Type {
		case PatchCreate:
			// Create new file
			if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return fmt.Errorf("create directory for %s: %w", p.File, err)
			}
			if err := os.WriteFile(path, []byte(p.Content), 0644); err != nil {
				return fmt.Errorf("create file %s: %w", p.File, err)
			}

		case PatchReplace:
			// Check if file exists
			if _, err := os.Stat(path); os.IsNotExist(err) {
				return fmt.Errorf("modify file %s: %w", p.File, err)
			}

			// Read existing file
			data, err := os.ReadFile(path)
			if err != nil {
				return fmt.Errorf("read file %s: %w", p.File, err)
			}

			// Split into lines
			lines := strings.Split(string(data), "\n")

			// Validate line range
			if p.FromLine < 1 || p.FromLine > len(lines) || p.ToLine < p.FromLine || p.ToLine > len(lines) {
				return fmt.Errorf("apply chunk in %s: line range out of bounds, file has %d lines", p.File, len(lines))
			}

			// Replace lines
			newLines := strings.Split(p.Content, "\n")
			lines = append(lines[:p.FromLine-1], append(newLines, lines[p.ToLine:]...)...)

			// Write back to file
			if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644); err != nil {
				return fmt.Errorf("write file %s: %w", p.File, err)
			}

		case PatchDelete:
			// Check if file exists
			if _, err := os.Stat(path); os.IsNotExist(err) {
				return fmt.Errorf("delete file %s: %w", p.File, err)
			}

			// Delete file
			if err := os.Remove(path); err != nil {
				return fmt.Errorf("delete file %s: %w", p.File, err)
			}

		default:
			return fmt.Errorf("unknown patch type: %s", p.Type)
		}
	}

	return nil
}

func (ps *PatchSet) UnmarshalJSON(data []byte) error {
	// Define a temporary struct to unmarshal into
	type tempPatch struct {
		File    string `json:"file"`
		Type    string `json:"type"`
		Content string `json:"content"`
	}
	type tempPatchSet struct {
		Patches []tempPatch   `json:"patches"`
		Commit  CommitMessage `json:"commit"`
	}

	// Unmarshal into temporary struct
	var temp tempPatchSet
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	// Validate and convert patches
	ps.Patches = make([]Chunk, len(temp.Patches))
	for i, p := range temp.Patches {
		// Validate required fields
		if p.File == "" {
			return fmt.Errorf("missing required field: file")
		}

		// Convert patch type
		var patchType PatchType
		switch p.Type {
		case "create":
			patchType = PatchCreate
		case "replace":
			patchType = PatchReplace
		case "delete":
			patchType = PatchDelete
		default:
			return fmt.Errorf("invalid patch type: %s", p.Type)
		}

		// Create chunk
		ps.Patches[i] = Chunk{
			File:    p.File,
			Type:    patchType,
			Content: p.Content,
		}
	}

	// Copy commit message
	ps.Commit = temp.Commit

	return nil
}
