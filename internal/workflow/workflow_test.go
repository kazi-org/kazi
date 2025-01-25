package workflow

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/shell"
)

type mockAIClient struct {
	response string
	err      error
}

func (m *mockAIClient) GetPatch(context.Context, string) (string, error) {
	if m.err != nil {
		return "", m.err
	}
	return m.response, nil
}

func TestProcessPrompt(t *testing.T) {
	tests := []struct {
		name        string
		prompt      config.Prompt
		global      config.GlobalConfig
		rules       map[string]string
		ctxStore    *contextstore.CodeContext
		mockResp    string
		mockErr     error
		wantErr     bool
		errContains string
	}{
		{
			name: "Successful patch",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "Add a function",
			},
			global: config.GlobalConfig{
				Workspace:    ".",
				BuildCommand: "", // Skip build for test
				TestCommand:  "", // Skip test for test
			},
			rules: map[string]string{
				"style": "gofmt",
			},
			mockResp: `{
				"patches": [
					{
						"file": "main.go",
						"type": "create",
						"content": "package main\n\nfunc main() {}\n"
					}
				],
				"commit": {
					"subject": "Add main function",
					"body": "Added a basic main function"
				}
			}`,
		},
		{
			name: "Invalid patch JSON",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "Add a function",
			},
			global: config.GlobalConfig{
				Workspace:    ".",
				BuildCommand: "",
				TestCommand:  "",
			},
			mockResp:    "invalid json",
			wantErr:     true,
			errContains: "invalid character",
		},
		{
			name: "AI client error",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "Add a function",
			},
			global: config.GlobalConfig{
				Workspace:    ".",
				BuildCommand: "",
				TestCommand:  "",
			},
			mockErr:     fmt.Errorf("AI service unavailable"),
			wantErr:     true,
			errContains: "AI service unavailable",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create temporary workspace
			tmpDir, err := os.MkdirTemp("", "kazi-workflow-test-*")
			if err != nil {
				t.Fatalf("Failed to create temp dir: %v", err)
			}
			defer os.RemoveAll(tmpDir)

			// Update workspace path
			tc.global.Workspace = tmpDir

			// Initialize git repo
			if err := initGitRepo(tmpDir); err != nil {
				t.Fatalf("Failed to initialize git repo: %v", err)
			}

			// Create mock AI client
			client := &mockAIClient{
				response: tc.mockResp,
				err:      tc.mockErr,
			}

			// Process prompt
			err = ProcessPrompt(tc.prompt, tc.global, tc.rules, tc.ctxStore, client)
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

			// Verify files were created/modified as expected
			if tc.mockResp != "" {
				mainPath := filepath.Join(tmpDir, "main.go")
				if _, err := os.Stat(mainPath); os.IsNotExist(err) {
					t.Error("main.go was not created")
				}

				// Verify git status is clean
				out, err := shell.RunCommandOutput(tmpDir, "git status --porcelain")
				if err != nil {
					t.Errorf("Failed to get git status: %v", err)
				}
				if out != "" {
					t.Errorf("Git status not clean, got: %s", out)
				}

				// Verify commit message
				out, err = shell.RunCommandOutput(tmpDir, "git log -1 --pretty=%B")
				if err != nil {
					t.Fatalf("Failed to get commit message: %v", err)
				}
				if !strings.Contains(out, "Add main function") {
					t.Error("Expected commit message not found in git log")
				}
			}
		})
	}
}

func TestBuildLLMRequest(t *testing.T) {
	tests := []struct {
		name     string
		prompt   config.Prompt
		global   config.GlobalConfig
		rules    map[string]string
		ctxStore *contextstore.CodeContext
		want     []string
	}{
		{
			name: "Basic request",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "do something",
			},
			global: config.GlobalConfig{
				Workspace:    "/test/workspace",
				BuildCommand: "go build",
				TestCommand:  "go test",
			},
			rules: map[string]string{
				"style": "gofmt",
				"test":  "required",
			},
			want: []string{
				"Project Rules:",
				"- style: gofmt",
				"- test: required",
				"Project Configuration:",
				"- Build Command: go build",
				"- Test Command: go test",
				"User Request:",
				"do something",
			},
		},
		{
			name: "With context",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "do something",
			},
			global: config.GlobalConfig{
				Workspace: "/test/workspace",
			},
			rules: nil,
			ctxStore: &contextstore.CodeContext{
				Files: map[string]*contextstore.FileContext{
					"main.go": {
						FilePath: "main.go",
						Imports:  []string{"fmt", "os"},
						Symbols: map[string]*contextstore.SymbolContext{
							"main": {
								Name:      "main",
								Kind:      "function",
								Package:   "main",
								Exported:  true,
								DocString: "main is the entry point",
							},
						},
					},
				},
			},
			want: []string{
				"Workspace Context:",
				"File: main.go",
				"Imports: fmt, os",
				"Symbol: main (function)",
				"User Request:",
				"do something",
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := buildLLMRequest(tc.prompt, tc.global, tc.rules, tc.ctxStore)
			for _, want := range tc.want {
				if !strings.Contains(got, want) {
					t.Errorf("request does not contain %q", want)
				}
			}
		})
	}
}

// initGitRepo initializes a git repository in the given directory
func initGitRepo(dir string) error {
	cmds := []struct {
		name string
		args []string
	}{
		{"git", []string{"init"}},
		{"git", []string{"config", "user.email", "test@example.com"}},
		{"git", []string{"config", "user.name", "Test User"}},
	}

	for _, cmd := range cmds {
		cmdStr := cmd.name
		if len(cmd.args) > 0 {
			cmdStr += " " + strings.Join(cmd.args, " ")
		}
		if err := shell.RunCommand(dir, cmdStr); err != nil {
			return err
		}
	}
	return nil
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}

func TestShowDiffAndCommit(t *testing.T) {
	tests := []struct {
		name        string
		prompt      config.Prompt
		workspace   string
		setupFiles  map[string]string
		patches     []patch.Chunk
		commit      patch.CommitMessage
		wantErr     bool
		errContains string
	}{
		{
			name: "Create and commit new file",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "Add main.go",
			},
			setupFiles: map[string]string{},
			patches: []patch.Chunk{
				{
					File:    "main.go",
					Type:    patch.PatchCreate,
					Content: "package main\n\nfunc main() {}\n",
				},
			},
			commit: patch.CommitMessage{
				Subject: "Add main function",
				Body:    "Added a basic main function",
			},
		},
		{
			name: "Modify existing file",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "Update main.go",
			},
			setupFiles: map[string]string{
				"main.go": "package main\n",
			},
			patches: []patch.Chunk{
				{
					File:     "main.go",
					Type:     patch.PatchReplace,
					FromLine: 1,
					ToLine:   1,
					Content:  "package main\n\nfunc main() {}\n",
				},
			},
			commit: patch.CommitMessage{
				Subject: "Update main function",
				Body:    "Added main function implementation",
			},
		},
		{
			name: "Delete file",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "Delete main.go",
			},
			setupFiles: map[string]string{
				"main.go": "package main\n",
			},
			patches: []patch.Chunk{
				{
					File:     "main.go",
					Type:     patch.PatchDelete,
					FromLine: 1,
					ToLine:   1,
				},
			},
			commit: patch.CommitMessage{
				Subject: "Remove main.go",
				Body:    "File is no longer needed",
			},
		},
		{
			name: "Invalid patch type",
			prompt: config.Prompt{
				Name:         "test",
				Instructions: "Invalid patch",
			},
			patches: []patch.Chunk{
				{
					File: "main.go",
					Type: "invalid",
				},
			},
			commit: patch.CommitMessage{
				Subject: "Invalid change",
			},
			wantErr:     true,
			errContains: "unknown patch type: invalid",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create temporary workspace
			tmpDir, err := os.MkdirTemp("", "kazi-workflow-test-*")
			if err != nil {
				t.Fatalf("Failed to create temp dir: %v", err)
			}
			defer os.RemoveAll(tmpDir)

			// Initialize git repo
			if err := initGitRepo(tmpDir); err != nil {
				t.Fatalf("Failed to initialize git repo: %v", err)
			}

			// Write setup files
			for name, content := range tc.setupFiles {
				path := filepath.Join(tmpDir, name)
				if err := os.WriteFile(path, []byte(content), 0644); err != nil {
					t.Fatalf("Failed to write file %s: %v", name, err)
				}
			}

			// Add initial files to git
			if len(tc.setupFiles) > 0 {
				if err := shell.RunCommand(tmpDir, "git add ."); err != nil {
					t.Fatalf("Failed to add files to git: %v", err)
				}
				if err := shell.RunCommand(tmpDir, "git commit -m 'Initial commit'"); err != nil {
					t.Fatalf("Failed to commit files: %v", err)
				}
			}

			// Create patch set
			ps := &patch.PatchSet{
				Patches: tc.patches,
				Commit:  tc.commit,
			}

			// Apply patches first
			if err := ps.Apply(tmpDir); err != nil {
				if tc.wantErr {
					if tc.errContains != "" && !contains(err.Error(), tc.errContains) {
						t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
					}
					return
				}
				t.Fatalf("Failed to apply patches: %v", err)
			}

			// Show diff and commit
			err = showDiffAndCommit(tc.prompt, tmpDir, ps)
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

			// Verify git status is clean
			out, err := shell.RunCommandOutput(tmpDir, "git status --porcelain")
			if err != nil {
				t.Errorf("Failed to get git status: %v", err)
			}
			if out != "" {
				t.Errorf("Git status not clean, got: %s", out)
			}

			// Verify commit message
			out, err = shell.RunCommandOutput(tmpDir, "git log -1 --pretty=%B")
			if err != nil {
				t.Fatalf("Failed to get commit message: %v", err)
			}
			if !strings.Contains(out, tc.commit.Subject) {
				t.Errorf("Commit subject %q not found in message: %s", tc.commit.Subject, out)
			}
			if tc.commit.Body != "" && !strings.Contains(out, tc.commit.Body) {
				t.Errorf("Commit body %q not found in message: %s", tc.commit.Body, out)
			}
		})
	}
}
