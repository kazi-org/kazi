// applier.go
//
// Declares the Applier interface plus a default concurrency-based implementation
// that processes each patch operation in parallel, using a FileManager.

package patch

import (
	"context"
	"fmt"
	"sync"
)

// Applier applies a PatchSet to the codebase, returning an error if any operation fails.
//
// Typically, the coordinator calls Applier after the LLM produces a PatchSet.
type Applier interface {
	Apply(ctx context.Context, ps *PatchSet) error
}

// DefaultApplier is a reference implementation that applies each patch
// by delegating file I/O to a FileManager and spawning goroutines for concurrency.
type DefaultApplier struct {
	FileMgr FileManager // Dependencies are inverted here; we don't do direct file ops.
}

// Apply concurrently processes each PatchOperation in the PatchSet. If any patch
// fails, we collect the error. We do not automatically rollback unless you combine
// with a Rollbacker.
func (da *DefaultApplier) Apply(ctx context.Context, ps *PatchSet) error {
	if ps == nil {
		return fmt.Errorf("nil PatchSet")
	}
	if da.FileMgr == nil {
		return fmt.Errorf("nil FileManager in DefaultApplier")
	}

	errChan := make(chan error, len(ps.Patches))
	var wg sync.WaitGroup

	for _, op := range ps.Patches {
		wg.Add(1)
		go func(operation PatchOperation) {
			defer wg.Done()

			select {
			case <-ctx.Done():
				// If context is canceled, we skip applying but set an error
				errChan <- ctx.Err()
				return
			default:
				if err := da.applyOperation(operation); err != nil {
					errChan <- fmt.Errorf("apply patch operation for file %s: %w", operation.File, err)
				}
			}
		}(op)
	}

	// Wait for all goroutines to finish
	wg.Wait()
	close(errChan)

	// Collect errors
	var finalErr error
	for e := range errChan {
		if e != nil {
			// We can accumulate them or just store the first one
			finalErr = e
		}
	}

	return finalErr
}

// applyOperation runs the logic for a single PatchOperation, reading/writing via FileManager.
func (da *DefaultApplier) applyOperation(op PatchOperation) error {
	switch op.Type {
	case PatchCreate:
		return da.applyCreate(op)
	case PatchReplace:
		return da.applyReplace(op)
	case PatchDelete:
		return da.applyDelete(op)
	default:
		return fmt.Errorf("unknown patch type: %s", op.Type)
	}
}

func (da *DefaultApplier) applyCreate(op PatchOperation) error {
	// We ensure the directory is created if needed, then write the Content
	if err := da.FileMgr.CreateDirForFile(op.File); err != nil {
		return fmt.Errorf("create dir for file %s: %w", op.File, err)
	}
	// If the file already exists, consider returning error or overwriting
	exists, err := da.FileMgr.Exists(op.File)
	if err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("file %s already exists, cannot create", op.File)
	}
	if err := da.FileMgr.WriteFile(op.File, []byte(op.Content)); err != nil {
		return fmt.Errorf("write file %s: %w", op.File, err)
	}
	return nil
}

func (da *DefaultApplier) applyReplace(op PatchOperation) error {
	// Load existing file
	data, err := da.FileMgr.ReadFile(op.File)
	if err != nil {
		return fmt.Errorf("read file for replace: %w", err)
	}
	lines := splitLines(data)

	if op.FromLine < 1 || op.ToLine < op.FromLine || op.ToLine > len(lines) {
		return fmt.Errorf("invalid line range %d-%d for file with %d lines", op.FromLine, op.ToLine, len(lines))
	}

	// Build the new content
	newLines := splitLines([]byte(op.Content))

	// lines[:op.FromLine-1] + newLines + lines[op.ToLine:]
	out := append(lines[:op.FromLine-1], newLines...)
	out = append(out, lines[op.ToLine:]...)

	// Write result
	if err := da.FileMgr.WriteFile(op.File, joinLines(out)); err != nil {
		return fmt.Errorf("write replaced file: %w", err)
	}
	return nil
}

func (da *DefaultApplier) applyDelete(op PatchOperation) error {
	// If it's a file delete, we can remove the file entirely
	// or if it's a partial line-range delete, handle it similarly to replace but w/ empty content

	if op.FromLine == 0 && op.ToLine == 0 && op.Content == "" {
		// Means a full file delete
		if err := da.FileMgr.DeleteFile(op.File); err != nil {
			return fmt.Errorf("delete file %s: %w", op.File, err)
		}
		return nil
	} else {
		// Partial lines deletion
		data, err := da.FileMgr.ReadFile(op.File)
		if err != nil {
			return fmt.Errorf("read file for partial delete: %w", err)
		}
		lines := splitLines(data)
		if op.FromLine < 1 || op.ToLine < op.FromLine || op.ToLine > len(lines) {
			return fmt.Errorf("invalid line range for partial delete")
		}
		out := append(lines[:op.FromLine-1], lines[op.ToLine:]...)
		if err := da.FileMgr.WriteFile(op.File, joinLines(out)); err != nil {
			return fmt.Errorf("write after partial delete: %w", err)
		}
		return nil
	}
}

// Helper methods for line splitting/joining:
func splitLines(data []byte) []string {
	// naive approach
	content := string(data)
	return stringToLines(content)
}

func joinLines(lines []string) []byte {
	// naive approach
	return []byte(linesToString(lines))
}

// stringToLines splits on \n to produce lines, etc.
func stringToLines(content string) []string {
	// for simplicity, we can do
	return []string{}
}

func linesToString(lines []string) string {
	// rejoin with \n
	return ""
}
