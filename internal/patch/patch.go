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
	// First validate all patches
	backups := make(map[string][]byte)
	filesToDelete := make(map[string]bool)

	// Validate all patches first
	for _, p := range ps.Patches {
		path := filepath.Join(workspace, p.File)

		switch p.Type {
		case PatchCreate:
			// Check if file already exists
			if _, err := os.Stat(path); err == nil {
				return fmt.Errorf("create file %s: file already exists", p.File)
			}

		case PatchReplace:
			// Check if file exists and validate line range
			data, err := os.ReadFile(path)
			if err != nil {
				return fmt.Errorf("read file %s: %w", p.File, err)
			}
			lines := strings.Split(string(data), "\n")
			if p.FromLine < 1 || p.FromLine > len(lines) || p.ToLine < p.FromLine || p.ToLine > len(lines) {
				return fmt.Errorf("apply chunk in %s: line range out of bounds, file has %d lines", p.File, len(lines))
			}
			// Store backup
			backups[p.File] = data

		case PatchDelete:
			// Check if file exists
			if _, err := os.Stat(path); os.IsNotExist(err) {
				return fmt.Errorf("delete file %s: file does not exist", p.File)
			}
			// Store backup
			data, err := os.ReadFile(path)
			if err != nil {
				return fmt.Errorf("read file %s: %w", p.File, err)
			}
			backups[p.File] = data
			filesToDelete[p.File] = true

		default:
			return fmt.Errorf("unknown patch type: %s", p.Type)
		}
	}

	// Apply all patches
	for _, p := range ps.Patches {
		path := filepath.Join(workspace, p.File)

		switch p.Type {
		case PatchCreate:
			if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return ps.rollback(workspace, backups, filesToDelete, fmt.Errorf("create directory for %s: %w", p.File, err))
			}
			if err := os.WriteFile(path, []byte(p.Content), 0644); err != nil {
				return ps.rollback(workspace, backups, filesToDelete, fmt.Errorf("create file %s: %w", p.File, err))
			}

		case PatchReplace:
			data, err := os.ReadFile(path)
			if err != nil {
				return ps.rollback(workspace, backups, filesToDelete, fmt.Errorf("read file %s: %w", p.File, err))
			}
			lines := strings.Split(string(data), "\n")
			newLines := strings.Split(p.Content, "\n")
			lines = append(lines[:p.FromLine-1], append(newLines, lines[p.ToLine:]...)...)
			if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644); err != nil {
				return ps.rollback(workspace, backups, filesToDelete, fmt.Errorf("write file %s: %w", p.File, err))
			}

		case PatchDelete:
			if err := os.Remove(path); err != nil {
				return ps.rollback(workspace, backups, filesToDelete, fmt.Errorf("delete file %s: %w", p.File, err))
			}
		}
	}

	return nil
}

// rollback restores files from backups and returns the original error
func (ps *PatchSet) rollback(workspace string, backups map[string][]byte, filesToDelete map[string]bool, err error) error {
	for file, data := range backups {
		path := filepath.Join(workspace, file)
		if filesToDelete[file] {
			// File was meant to be deleted, restore it
			if writeErr := os.WriteFile(path, data, 0644); writeErr != nil {
				return fmt.Errorf("rollback failed - could not restore %s: %v (original error: %w)", file, writeErr, err)
			}
		} else if _, statErr := os.Stat(path); statErr == nil {
			// File exists and needs to be restored
			if writeErr := os.WriteFile(path, data, 0644); writeErr != nil {
				return fmt.Errorf("rollback failed - could not restore %s: %v (original error: %w)", file, writeErr, err)
			}
		}
	}
	return fmt.Errorf("operation rolled back: %w", err)
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
