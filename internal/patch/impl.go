package patch

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// defaultFileManager implements FileManager interface
type defaultFileManager struct {
	workspace string
}

// NewFileManager creates a new file manager for the given workspace
func NewFileManager(workspace string) FileManager {
	return &defaultFileManager{
		workspace: workspace,
	}
}

func (fm *defaultFileManager) ReadFile(path string) ([]byte, error) {
	fullPath := filepath.Join(fm.workspace, path)
	data, err := os.ReadFile(fullPath)
	if os.IsNotExist(err) {
		return nil, &ErrFileNotFound{Path: path}
	}
	if err != nil {
		return nil, fmt.Errorf("read file %s: %w", path, err)
	}
	return data, nil
}

func (fm *defaultFileManager) WriteFile(path string, data []byte, perm os.FileMode) error {
	fullPath := filepath.Join(fm.workspace, path)
	if err := os.WriteFile(fullPath, data, perm); err != nil {
		return fmt.Errorf("write file %s: %w", path, err)
	}
	return nil
}

func (fm *defaultFileManager) DeleteFile(path string) error {
	fullPath := filepath.Join(fm.workspace, path)
	if err := os.Remove(fullPath); err != nil {
		if os.IsNotExist(err) {
			return &ErrFileNotFound{Path: path}
		}
		return fmt.Errorf("delete file %s: %w", path, err)
	}
	return nil
}

func (fm *defaultFileManager) CreateDir(path string, perm os.FileMode) error {
	fullPath := filepath.Join(fm.workspace, path)
	if err := os.MkdirAll(fullPath, perm); err != nil {
		return fmt.Errorf("create directory %s: %w", path, err)
	}
	return nil
}

func (fm *defaultFileManager) Close() error {
	return nil // No cleanup needed for basic file manager
}

// defaultPatchValidator implements PatchValidator interface
type defaultPatchValidator struct {
	fm FileReader
}

// NewPatchValidator creates a new patch validator
func NewPatchValidator(fm FileReader) PatchValidator {
	return &defaultPatchValidator{
		fm: fm,
	}
}

func (pv *defaultPatchValidator) Validate(ctx context.Context, chunk Chunk) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	switch chunk.Type {
	case PatchCreate:
		// Check if file already exists
		_, err := pv.fm.ReadFile(chunk.File)
		if err == nil {
			return &ErrFileExists{Path: chunk.File}
		}
		if _, ok := err.(*ErrFileNotFound); !ok {
			return fmt.Errorf("validate create %s: %w", chunk.File, err)
		}

	case PatchReplace:
		// Check if file exists and validate line range
		data, err := pv.fm.ReadFile(chunk.File)
		if err != nil {
			return fmt.Errorf("validate replace %s: %w", chunk.File, err)
		}
		lines := strings.Split(string(data), "\n")
		if chunk.FromLine < 1 || chunk.FromLine > len(lines) || chunk.ToLine < chunk.FromLine || chunk.ToLine > len(lines) {
			return fmt.Errorf("line range out of bounds in %s: file has %d lines", chunk.File, len(lines))
		}

	case PatchDelete:
		// Check if file exists
		_, err := pv.fm.ReadFile(chunk.File)
		if err != nil {
			return fmt.Errorf("validate delete %s: %w", chunk.File, err)
		}

	default:
		return &ErrInvalidPatchType{Type: chunk.Type}
	}

	return nil
}

// defaultPatchApplier implements PatchApplier interface
type defaultPatchApplier struct {
	fm FileManager
}

// NewPatchApplier creates a new patch applier
func NewPatchApplier(fm FileManager) PatchApplier {
	return &defaultPatchApplier{
		fm: fm,
	}
}

func (pa *defaultPatchApplier) Apply(ctx context.Context, chunk Chunk) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	switch chunk.Type {
	case PatchCreate:
		if err := pa.fm.CreateDir(filepath.Dir(chunk.File), 0755); err != nil {
			return fmt.Errorf("create directory for %s: %w", chunk.File, err)
		}
		if err := pa.fm.WriteFile(chunk.File, []byte(chunk.Content), 0644); err != nil {
			return fmt.Errorf("create file %s: %w", chunk.File, err)
		}

	case PatchReplace:
		data, err := pa.fm.ReadFile(chunk.File)
		if err != nil {
			return fmt.Errorf("read file for replace %s: %w", chunk.File, err)
		}
		lines := strings.Split(string(data), "\n")
		newLines := strings.Split(chunk.Content, "\n")
		lines = append(lines[:chunk.FromLine-1], append(newLines, lines[chunk.ToLine:]...)...)
		if err := pa.fm.WriteFile(chunk.File, []byte(strings.Join(lines, "\n")), 0644); err != nil {
			return fmt.Errorf("write file for replace %s: %w", chunk.File, err)
		}

	case PatchDelete:
		if err := pa.fm.DeleteFile(chunk.File); err != nil {
			return fmt.Errorf("delete file %s: %w", chunk.File, err)
		}

	default:
		return &ErrInvalidPatchType{Type: chunk.Type}
	}

	return nil
}

// defaultPatchRollbacker implements PatchRollbacker interface
type defaultPatchRollbacker struct {
	fm       FileManager
	backups  map[string][]byte
	toDelete map[string]bool
}

// NewPatchRollbacker creates a new patch rollbacker
func NewPatchRollbacker(fm FileManager) PatchRollbacker {
	return &defaultPatchRollbacker{
		fm:       fm,
		backups:  make(map[string][]byte),
		toDelete: make(map[string]bool),
	}
}

func (pr *defaultPatchRollbacker) Backup(path string, isDelete bool) error {
	data, err := pr.fm.ReadFile(path)
	if err != nil {
		return fmt.Errorf("backup file %s: %w", path, err)
	}
	pr.backups[path] = data
	if isDelete {
		pr.toDelete[path] = true
	}
	return nil
}

func (pr *defaultPatchRollbacker) Rollback(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	var errs []string
	for file, data := range pr.backups {
		if pr.toDelete[file] {
			// File was meant to be deleted, restore it
			if err := pr.fm.WriteFile(file, data, 0644); err != nil {
				errs = append(errs, fmt.Sprintf("could not restore %s: %v", file, err))
			}
		} else {
			// File exists and needs to be restored
			if err := pr.fm.WriteFile(file, data, 0644); err != nil {
				errs = append(errs, fmt.Sprintf("could not restore %s: %v", file, err))
			}
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("rollback failed: %s", strings.Join(errs, "; "))
	}
	return nil
}
