package patch

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPatchSet_Apply(t *testing.T) {
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
			errContains: "no such file",
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

			err = ps.Apply(tmpDir)
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error but got nil")
				}
				if tc.errContains != "" && !contains(err.Error(), tc.errContains) {
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
				if tc.errContains != "" && !contains(err.Error(), tc.errContains) {
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

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
