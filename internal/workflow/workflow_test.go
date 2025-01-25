package workflow

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/go-git/go-git/v5"
	kaziconfig "github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/shell"
)

// mockAIClient implements ai.LLMClient for testing
type mockAIClient struct {
	response string
}

func (m *mockAIClient) GetPatch(context.Context, string) (string, error) {
	return m.response, nil
}

func TestProcessPrompt(t *testing.T) {
	tests := []struct {
		name        string
		prompt      kaziconfig.Prompt
		global      kaziconfig.GlobalConfig
		rules       []string
		ctx         *contextstore.CodeContext
		mockResp    string
		wantErr     bool
		errContains string
	}{
		{
			name: "Success",
			prompt: kaziconfig.Prompt{
				Name:         "Test",
				Instructions: "Add a function",
			},
			global: kaziconfig.GlobalConfig{
				Workspace:   ".",
				LintCommand: "",
				TestCommand: "",
			},
			rules: []string{"Use gofmt for formatting"},
			mockResp: `{
				"patches": [{
					"file": "main.go",
					"type": "create",
					"content": "package main\n\nfunc main() {}\n"
				}],
				"commit": {
					"subject": "Add main function",
					"body": "Added main function implementation"
				}
			}`,
		},
		{
			name: "Invalid JSON response",
			prompt: kaziconfig.Prompt{
				Name:         "Test",
				Instructions: "Add a function",
			},
			global: kaziconfig.GlobalConfig{
				Workspace:   ".",
				LintCommand: "",
				TestCommand: "",
			},
			mockResp:    "invalid json",
			wantErr:     true,
			errContains: "parse patch JSON",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create temp workspace
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

			// Create mock client
			client := &mockAIClient{response: tc.mockResp}

			// Process prompt
			err = ProcessPrompt(tc.prompt, tc.global, tc.rules, tc.ctx, client)
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
		prompt   kaziconfig.Prompt
		global   kaziconfig.GlobalConfig
		rules    []string
		ctx      *contextstore.CodeContext
		contains []string
	}{
		{
			name: "Basic request",
			prompt: kaziconfig.Prompt{
				Name:         "Test",
				Instructions: "do something",
			},
			global: kaziconfig.GlobalConfig{
				Workspace:   "/test/workspace",
				LintCommand: "go vet ./...",
				TestCommand: "go test ./...",
			},
			rules: []string{
				"Use gofmt for formatting",
				"Write tests for all functions",
			},
			contains: []string{
				"Project Rules:",
				"- Use gofmt for formatting",
				"- Write tests for all functions",
				"Project Configuration:",
				"- Lint Command: go vet ./...",
				"- Test Command: go test ./...",
				"User Request:",
				"do something",
			},
		},
		{
			name: "With context",
			prompt: kaziconfig.Prompt{
				Name:         "test",
				Instructions: "do something",
			},
			global: kaziconfig.GlobalConfig{
				Workspace: "/test/workspace",
			},
			rules: nil,
			ctx: &contextstore.CodeContext{
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
			contains: []string{
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
			got := buildLLMRequest(tc.prompt, tc.global, tc.rules, tc.ctx)
			for _, want := range tc.contains {
				if !strings.Contains(got, want) {
					t.Errorf("request does not contain %q", want)
				}
			}
		})
	}
}

// initGitRepo initializes a git repository in the given directory
func initGitRepo(dir string) error {
	// Initialize repository
	if _, err := git.PlainInit(dir, false); err != nil {
		return fmt.Errorf("init git repo: %w", err)
	}

	// Configure git user using shell commands
	if err := shell.RunCommand(dir, "git config user.name 'Test User'"); err != nil {
		return fmt.Errorf("set git user name: %w", err)
	}
	if err := shell.RunCommand(dir, "git config user.email 'test@example.com'"); err != nil {
		return fmt.Errorf("set git user email: %w", err)
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
		prompt      kaziconfig.Prompt
		workspace   string
		setupFiles  map[string]string
		patches     []patch.Chunk
		commit      patch.CommitMessage
		wantErr     bool
		errContains string
	}{
		{
			name: "Create and commit new file",
			prompt: kaziconfig.Prompt{
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
			prompt: kaziconfig.Prompt{
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
			prompt: kaziconfig.Prompt{
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
			prompt: kaziconfig.Prompt{
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
