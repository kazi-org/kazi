package workflow

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	kaziconfig "github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
)

// mockAIClient implements ai.LLMClient for testing
type mockAIClient struct {
	response string
}

func (m *mockAIClient) GetPatch(context.Context, string) (string, error) {
	return m.response, nil
}

// initGitRepo initializes a git repository in the given directory
func initGitRepo(dir string) error {
	// Initialize repository
	repo, err := git.PlainInit(dir, false)
	if err != nil {
		return fmt.Errorf("init git repo: %w", err)
	}

	// Configure git user
	cfg := config.NewConfig()
	cfg.User.Name = "Test User"
	cfg.User.Email = "test@example.com"

	if err := repo.SetConfig(cfg); err != nil {
		return fmt.Errorf("set git config: %w", err)
	}

	return nil
}

// getGitStatus returns the status of a git repository
func getGitStatus(dir string) (string, error) {
	repo, err := git.PlainOpen(dir)
	if err != nil {
		return "", fmt.Errorf("open git repo: %w", err)
	}

	wt, err := repo.Worktree()
	if err != nil {
		return "", fmt.Errorf("get worktree: %w", err)
	}

	status, err := wt.Status()
	if err != nil {
		return "", fmt.Errorf("get status: %w", err)
	}

	return status.String(), nil
}

// getLastCommitMessage returns the message of the last commit
func getLastCommitMessage(dir string) (string, error) {
	repo, err := git.PlainOpen(dir)
	if err != nil {
		return "", fmt.Errorf("open git repo: %w", err)
	}

	ref, err := repo.Head()
	if err != nil {
		return "", fmt.Errorf("get HEAD: %w", err)
	}

	commit, err := repo.CommitObject(ref.Hash())
	if err != nil {
		return "", fmt.Errorf("get commit: %w", err)
	}

	return commit.Message, nil
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
		responses   []string
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
			responses: []string{"yes"},
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
			responses:   []string{"yes"},
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

			// Create mock client and interaction
			client := &mockAIClient{response: tc.mockResp}
			interaction := newMockInteraction(tc.responses)

			// Process prompt
			err = ProcessPrompt(tc.prompt, tc.global, tc.rules, tc.ctx, client, interaction)
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
				status, err := getGitStatus(tmpDir)
				if err != nil {
					t.Errorf("Failed to get git status: %v", err)
				}
				if status != "" {
					t.Errorf("Git status not clean, got: %s", status)
				}

				// Verify commit message
				msg, err := getLastCommitMessage(tmpDir)
				if err != nil {
					t.Fatalf("Failed to get commit message: %v", err)
				}
				if !strings.Contains(msg, "Add main function") {
					t.Error("Expected commit message not found in git log")
				}
			}
		})
	}
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}

func TestRequestBuilder(t *testing.T) {
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
			builder := newRequestBuilder(tc.rules, tc.global, tc.ctx)
			got := builder.Build(tc.prompt)
			for _, want := range tc.contains {
				if !strings.Contains(got, want) {
					t.Errorf("request does not contain %q", want)
				}
			}
		})
	}
}

func TestGitCommitter(t *testing.T) {
	tests := []struct {
		name         string
		setupFiles   map[string]string
		commitMsg    string
		wantErr      bool
		errContains  string
		shouldCommit bool
	}{
		{
			name: "Commit changes",
			setupFiles: map[string]string{
				"test.txt": "test content",
			},
			commitMsg:    "Add test file",
			shouldCommit: true,
		},
		{
			name:         "Empty workspace",
			commitMsg:    "Empty commit",
			shouldCommit: false,
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

			// Initialize git repo
			if err := initGitRepo(tmpDir); err != nil {
				t.Fatalf("Failed to initialize git repo: %v", err)
			}

			// Create setup files
			for name, content := range tc.setupFiles {
				path := filepath.Join(tmpDir, name)
				if err := os.WriteFile(path, []byte(content), 0644); err != nil {
					t.Fatalf("Failed to write file %s: %v", name, err)
				}
			}

			// Create git committer
			committer, err := newGitCommitter(tmpDir)
			if err != nil {
				t.Fatalf("Failed to create git committer: %v", err)
			}

			// Get status and commit
			status, err := committer.Status(context.Background())
			if err != nil {
				t.Fatalf("Failed to get status: %v", err)
			}

			if !status.IsClean() {
				if err := committer.Commit(context.Background(), tc.commitMsg); err != nil {
					if tc.wantErr {
						if tc.errContains != "" && !strings.Contains(err.Error(), tc.errContains) {
							t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
						}
						return
					}
					t.Fatalf("Failed to commit: %v", err)
				}
			}

			// Verify commit only if we should have committed
			if tc.shouldCommit {
				msg, err := getLastCommitMessage(tmpDir)
				if err != nil {
					t.Fatalf("Failed to get commit message: %v", err)
				}
				if !strings.Contains(msg, tc.commitMsg) {
					t.Errorf("Commit message %q not found in git log", tc.commitMsg)
				}
			}
		})
	}
}

func TestValidator(t *testing.T) {
	tests := []struct {
		name        string
		config      kaziconfig.GlobalConfig
		wantErr     bool
		errContains string
	}{
		{
			name: "No commands",
			config: kaziconfig.GlobalConfig{
				Workspace: ".",
			},
		},
		{
			name: "With commands",
			config: kaziconfig.GlobalConfig{
				Workspace:   ".",
				LintCommand: "echo 'lint'",
				TestCommand: "echo 'test'",
			},
		},
		{
			name: "Failed command",
			config: kaziconfig.GlobalConfig{
				Workspace:   ".",
				LintCommand: "exit 1",
			},
			wantErr:     true,
			errContains: "lint failed",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			validator := newValidator(tc.config)
			err := validator.Validate(context.Background())
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
