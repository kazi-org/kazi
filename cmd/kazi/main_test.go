package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kazi-org/kazi/internal/config"
)

// testCase represents a single integration test scenario
type testCase struct {
	name          string     // descriptive name of the test case
	configContent string     // content of kazi.yml file
	setupFiles    setupFiles // map of relative path to file content
	wantErr       bool       // whether we expect an error
	errContains   string     // expected error substring (if wantErr is true)
}

// setupFiles is a map of relative file paths to their content
type setupFiles map[string]string

// setupTestWorkspace creates a temporary workspace with the given files and configuration
func setupTestWorkspace(t *testing.T, files setupFiles, configContent string) (string, func()) {
	t.Helper()

	// Create temporary directory
	tmpDir, err := os.MkdirTemp("", "kazi-integration-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}

	// Create cleanup function
	cleanup := func() {
		if err := os.RemoveAll(tmpDir); err != nil {
			t.Errorf("Failed to cleanup temp dir: %v", err)
		}
	}

	// Write files
	for rel, content := range files {
		path := filepath.Join(tmpDir, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			cleanup()
			t.Fatalf("Failed to create directory for %s: %v", rel, err)
		}
		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			cleanup()
			t.Fatalf("Failed to write file %s: %v", rel, err)
		}
	}

	// Write config if provided
	if configContent != "" {
		cfgPath := filepath.Join(tmpDir, "kazi.yml")
		if err := os.WriteFile(cfgPath, []byte(configContent), 0644); err != nil {
			cleanup()
			t.Fatalf("Failed to write kazi.yml: %v", err)
		}
	}

	// Initialize git repo
	if err := os.Mkdir(filepath.Join(tmpDir, ".git"), 0755); err != nil {
		cleanup()
		t.Fatalf("Failed to create .git directory: %v", err)
	}
	if err := initGitRepo(tmpDir); err != nil {
		cleanup()
		t.Fatalf("Failed to initialize git repo: %v", err)
	}

	return tmpDir, cleanup
}

func TestKaziIntegration(t *testing.T) {
	tests := []testCase{
		{
			name:          "Missing config file",
			configContent: "",
			setupFiles: setupFiles{
				"main.go": `package main; func main() {}`,
			},
			wantErr:     true,
			errContains: "read config file",
		},
		{
			name: "Non-existent workspace path",
			configContent: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: test-project
spec:
  global:
    workspace: "/nonexistent/path"
  rules:
    - "We use snake_case"
    - "All exported items start with capital letter"
  prompts:
    - name: "Test"
      instructions: "add test"`,
			setupFiles: setupFiles{
				"main.go": `package main
func main() {}
`,
			},
			wantErr:     true,
			errContains: "workspace path does not exist",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Setup test workspace
			tmpDir, cleanup := setupTestWorkspace(t, tc.setupFiles, tc.configContent)
			defer cleanup()

			// Load configuration
			cfg, err := config.LoadConfig(filepath.Join(tmpDir, "kazi.yml"))
			if err != nil {
				if !tc.wantErr {
					t.Fatalf("Unexpected error loading config: %v", err)
				}
				if tc.errContains != "" && !contains(err.Error(), tc.errContains) {
					t.Fatalf("Error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}

			// Update workspace paths
			if cfg != nil {
				if tc.name == "Non-existent workspace path" {
					cfg.Spec.Global.Workspace = filepath.Join(tmpDir, "no_such_dir")
				} else {
					cfg.Spec.Global.Workspace = tmpDir
				}
			}

			// Create and run app
			app, err := NewApp(cfg, &mockAIClient{})
			if err != nil {
				t.Fatalf("Failed to create app: %v", err)
			}

			err = app.Run()
			if err != nil {
				if !tc.wantErr {
					t.Fatalf("Unexpected error running app: %v", err)
				}
				if tc.errContains != "" && !contains(err.Error(), tc.errContains) {
					t.Fatalf("Error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}

			if tc.wantErr {
				t.Fatalf("Expected error but got none")
			}
		})
	}
}

// mockAIClient implements ai.LLMClient for testing
type mockAIClient struct{}

func (m *mockAIClient) GetPatch(context.Context, string) (string, error) {
	return `{
		"patches": [{
			"file": "main.go",
			"type": "replace",
			"fromLine": 1,
			"toLine": 4,
			"content": "package main\n\nfunc Foo() {}\n\nfunc main() {}\n"
		}],
		"commit": {
			"subject": "Add Foo function",
			"body": "Added new Foo function as requested"
		}
	}`, nil
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
		{"git", []string{"add", "."}},
		{"git", []string{"commit", "-m", "Initial commit"}},
	}

	for _, cmd := range cmds {
		c := exec.Command(cmd.name, cmd.args...)
		c.Dir = dir
		if err := c.Run(); err != nil {
			return fmt.Errorf("failed to run %s %v: %w", cmd.name, cmd.args, err)
		}
	}
	return nil
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
