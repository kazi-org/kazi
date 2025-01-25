package patch

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestApplier_Apply(t *testing.T) {
	tests := []struct {
		name        string
		patches     []Chunk
		setupFiles  map[string]string
		wantFiles   map[string]string
		wantErr     bool
		errContains string
	}{
		{
			name: "Create new file",
			patches: []Chunk{
				{
					File:    "new.txt",
					Type:    PatchCreate,
					Content: "hello world",
				},
			},
			setupFiles: map[string]string{},
			wantFiles: map[string]string{
				"new.txt": "hello world",
			},
		},
		{
			name: "Modify existing file",
			patches: []Chunk{
				{
					File:     "existing.txt",
					Type:     PatchReplace,
					Content:  "modified content",
					FromLine: 1,
					ToLine:   1,
				},
			},
			setupFiles: map[string]string{
				"existing.txt": "original content",
			},
			wantFiles: map[string]string{
				"existing.txt": "modified content",
			},
		},
		{
			name: "Delete file",
			patches: []Chunk{
				{
					File:     "to_delete.txt",
					Type:     PatchDelete,
					FromLine: 1,
					ToLine:   1,
				},
			},
			setupFiles: map[string]string{
				"to_delete.txt": "content to delete",
			},
			wantFiles: map[string]string{},
		},
		{
			name: "Invalid patch type",
			patches: []Chunk{
				{
					File: "test.txt",
					Type: "invalid",
				},
			},
			wantErr:     true,
			errContains: "unknown patch type: invalid",
		},
		{
			name: "Modify non-existent file",
			patches: []Chunk{
				{
					File:     "nonexistent.txt",
					Type:     PatchReplace,
					Content:  "new content",
					FromLine: 1,
					ToLine:   1,
				},
			},
			wantErr:     true,
			errContains: "no such file",
		},
		{
			name: "Delete non-existent file",
			patches: []Chunk{
				{
					File:     "nonexistent.txt",
					Type:     PatchDelete,
					FromLine: 1,
					ToLine:   1,
				},
			},
			wantErr:     true,
			errContains: "file does not exist",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create temporary workspace
			tmpDir, err := os.MkdirTemp("", "kazi-patch-test-*")
			if err != nil {
				t.Fatalf("Failed to create temp dir: %v", err)
			}
			defer os.RemoveAll(tmpDir)

			// Setup initial files
			for name, content := range tc.setupFiles {
				path := filepath.Join(tmpDir, name)
				if err := os.WriteFile(path, []byte(content), 0644); err != nil {
					t.Fatalf("Failed to write setup file %s: %v", name, err)
				}
			}

			// Create and apply patch set
			ps := &PatchSet{
				Patches: tc.patches,
				Commit: CommitMessage{
					Subject: "test commit",
				},
			}

			applier := NewApplier(tmpDir)
			err = applier.Apply(ps)

			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error but got nil")
				}
				if tc.errContains != "" && !strings.Contains(err.Error(), tc.errContains) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Verify file contents
			for name, wantContent := range tc.wantFiles {
				path := filepath.Join(tmpDir, name)
				content, err := os.ReadFile(path)
				if err != nil {
					t.Errorf("Failed to read file %s: %v", name, err)
					continue
				}
				if string(content) != wantContent {
					t.Errorf("File %s content = %q, want %q", name, content, wantContent)
				}
			}

			// Verify deleted files
			for name := range tc.setupFiles {
				if _, wantExists := tc.wantFiles[name]; !wantExists {
					path := filepath.Join(tmpDir, name)
					if _, err := os.Stat(path); !os.IsNotExist(err) {
						t.Errorf("File %s should not exist", name)
					}
				}
			}
		})
	}
}

func TestPatchSet_UnmarshalJSON(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		want        *PatchSet
		wantErr     bool
		errContains string
	}{
		{
			name: "Valid patch set",
			input: `{
				"patches": [
					{
						"file": "test.txt",
						"type": "create",
						"content": "hello"
					}
				],
				"commit": {
					"subject": "test commit",
					"body": "test body"
				}
			}`,
			want: &PatchSet{
				Patches: []Chunk{
					{
						File:    "test.txt",
						Type:    PatchCreate,
						Content: "hello",
					},
				},
				Commit: CommitMessage{
					Subject: "test commit",
					Body:    "test body",
				},
			},
		},
		{
			name:        "Invalid JSON",
			input:       "invalid json",
			wantErr:     true,
			errContains: "invalid character",
		},
		{
			name: "Missing required fields",
			input: `{
				"patches": [
					{
						"type": "create",
						"content": "hello"
					}
				]
			}`,
			wantErr:     true,
			errContains: "missing required field: file",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var got PatchSet
			err := json.Unmarshal([]byte(tc.input), &got)

			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error but got nil")
				}
				if tc.errContains != "" && !strings.Contains(err.Error(), tc.errContains) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if len(got.Patches) != len(tc.want.Patches) {
				t.Errorf("got %d patches, want %d", len(got.Patches), len(tc.want.Patches))
				return
			}

			for i, p := range got.Patches {
				want := tc.want.Patches[i]
				if p.File != want.File || p.Type != want.Type || p.Content != want.Content {
					t.Errorf("patch[%d] = %+v, want %+v", i, p, want)
				}
			}

			if got.Commit.Subject != tc.want.Commit.Subject || got.Commit.Body != tc.want.Commit.Body {
				t.Errorf("commit = %+v, want %+v", got.Commit, tc.want.Commit)
			}
		})
	}
}

// TestFileManager tests the FileManager implementation
func TestFileManager(t *testing.T) {
	// Create temporary workspace
	tmpDir, err := os.MkdirTemp("", "kazi-filemanager-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	fm := NewFileManager(tmpDir)

	// Test CreateDir
	t.Run("CreateDir", func(t *testing.T) {
		if err := fm.CreateDir("test/subdir", 0755); err != nil {
			t.Fatalf("CreateDir failed: %v", err)
		}
		path := filepath.Join(tmpDir, "test/subdir")
		if info, err := os.Stat(path); err != nil || !info.IsDir() {
			t.Errorf("Directory not created correctly")
		}
	})

	// Test WriteFile and ReadFile
	t.Run("WriteFile and ReadFile", func(t *testing.T) {
		content := []byte("test content")
		if err := fm.WriteFile("test/file.txt", content, 0644); err != nil {
			t.Fatalf("WriteFile failed: %v", err)
		}

		got, err := fm.ReadFile("test/file.txt")
		if err != nil {
			t.Fatalf("ReadFile failed: %v", err)
		}
		if string(got) != string(content) {
			t.Errorf("ReadFile content = %q, want %q", got, content)
		}
	})

	// Test DeleteFile
	t.Run("DeleteFile", func(t *testing.T) {
		if err := fm.DeleteFile("test/file.txt"); err != nil {
			t.Fatalf("DeleteFile failed: %v", err)
		}
		path := filepath.Join(tmpDir, "test/file.txt")
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("File not deleted")
		}
	})
}

// TestPatchValidator tests the PatchValidator implementation
func TestPatchValidator(t *testing.T) {
	// Create temporary workspace
	tmpDir, err := os.MkdirTemp("", "kazi-validator-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	fm := NewFileManager(tmpDir)
	validator := NewPatchValidator(fm)
	ctx := context.Background()

	// Setup test file
	if err := fm.WriteFile("test.txt", []byte("line1\nline2\nline3\n"), 0644); err != nil {
		t.Fatalf("Failed to setup test file: %v", err)
	}

	tests := []struct {
		name        string
		chunk       Chunk
		wantErr     bool
		errContains string
	}{
		{
			name: "Valid create",
			chunk: Chunk{
				File:    "new.txt",
				Type:    PatchCreate,
				Content: "test",
			},
		},
		{
			name: "Create existing file",
			chunk: Chunk{
				File:    "test.txt",
				Type:    PatchCreate,
				Content: "test",
			},
			wantErr:     true,
			errContains: "file already exists",
		},
		{
			name: "Valid replace",
			chunk: Chunk{
				File:     "test.txt",
				Type:     PatchReplace,
				FromLine: 1,
				ToLine:   2,
				Content:  "new content",
			},
		},
		{
			name: "Replace invalid range",
			chunk: Chunk{
				File:     "test.txt",
				Type:     PatchReplace,
				FromLine: 1,
				ToLine:   10,
				Content:  "test",
			},
			wantErr:     true,
			errContains: "line range out of bounds",
		},
		{
			name: "Delete non-existent",
			chunk: Chunk{
				File: "nonexistent.txt",
				Type: PatchDelete,
			},
			wantErr:     true,
			errContains: "file does not exist",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := validator.Validate(ctx, tc.chunk)
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error but got nil")
				}
				if tc.errContains != "" && !strings.Contains(err.Error(), tc.errContains) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

// TestPatchRollbacker tests the PatchRollbacker implementation
func TestPatchRollbacker(t *testing.T) {
	// Create temporary workspace
	tmpDir, err := os.MkdirTemp("", "kazi-rollbacker-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	fm := NewFileManager(tmpDir)
	rollbacker := NewPatchRollbacker(fm)
	ctx := context.Background()

	// Setup test files
	files := map[string]string{
		"file1.txt": "content1",
		"file2.txt": "content2",
	}
	for name, content := range files {
		if err := fm.WriteFile(name, []byte(content), 0644); err != nil {
			t.Fatalf("Failed to setup file %s: %v", name, err)
		}
	}

	// Backup files
	for name, isDelete := range map[string]bool{
		"file1.txt": true,
		"file2.txt": false,
	} {
		if err := rollbacker.(*defaultPatchRollbacker).Backup(name, isDelete); err != nil {
			t.Fatalf("Failed to backup %s: %v", name, err)
		}
	}

	// Modify files
	if err := fm.WriteFile("file2.txt", []byte("modified"), 0644); err != nil {
		t.Fatalf("Failed to modify file: %v", err)
	}
	if err := fm.DeleteFile("file1.txt"); err != nil {
		t.Fatalf("Failed to delete file: %v", err)
	}

	// Test rollback
	if err := rollbacker.Rollback(ctx); err != nil {
		t.Fatalf("Rollback failed: %v", err)
	}

	// Verify files restored
	for name, wantContent := range files {
		content, err := fm.ReadFile(name)
		if err != nil {
			t.Errorf("Failed to read file %s: %v", name, err)
			continue
		}
		if string(content) != wantContent {
			t.Errorf("File %s content = %q, want %q", name, content, wantContent)
		}
	}
}
