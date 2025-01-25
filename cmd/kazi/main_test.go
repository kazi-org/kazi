package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/lsp"
)

func TestKaziIntegration(t *testing.T) {
	type testCase struct {
		name          string
		configContent string
		setupFiles    map[string]string // relative path -> file content
		wantErr       bool
	}

	// We'll define a few scenarios
	tests := []testCase{
		{
			name: "Missing config file",
			// No config content => we won't create the file
			configContent: "",
			setupFiles: map[string]string{
				"main.go": `package main; func main() {}`,
			},
			wantErr: true, // we expect error because there's no kazi.yml
		},
		{
			name: "Minimal config with no build/test commands",
			configContent: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: minimal
spec:
  global:
    workspace: "."
    languageServer:
      name: gopls
      command: gopls
    buildCommand: ""
    testCommand: ""
  rules:
    style: "We use snake_case"
  prompts:
    - name: "Add function"
      instructions: "Add a function named Foo in main.go"
`,
			setupFiles: map[string]string{
				"main.go": `package main

func main() {}
`,
			},
			wantErr: false,
		},
		{
			name: "Non-existent workspace path",
			// The config references a directory that doesn't exist
			configContent: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: bad-workspace
spec:
  global:
    workspace: "./no_such_dir"
    languageServer:
      name: gopls
      command: gopls
    buildCommand: ""
    testCommand: ""
  rules:
    naming: "All exported items start with capital letter"
  prompts:
    - name: "Test"
      instructions: "Nothing"
`,
			setupFiles: map[string]string{
				"main.go": `package main
func main() {}
`,
			},
			wantErr: true, // because the workspace doesn't exist
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// 1) Create ephemeral directory
			tmpDir, err := os.MkdirTemp("", "kazi-integration-*")
			if err != nil {
				t.Fatalf("TempDir: %v", err)
			}
			defer os.RemoveAll(tmpDir)

			// 2) Write setup files to the ephemeral workspace
			for rel, content := range tc.setupFiles {
				path := filepath.Join(tmpDir, rel)
				if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
					t.Fatalf("MkdirAll for %s: %v", rel, err)
				}
				if werr := os.WriteFile(path, []byte(content), 0644); werr != nil {
					t.Fatalf("Write file %s: %v", rel, werr)
				}
			}

			// 3) Optionally write config to kazi.yml if configContent is not empty
			cfgPath := filepath.Join(tmpDir, "kazi.yml")
			if tc.configContent != "" {
				if writeErr := os.WriteFile(cfgPath, []byte(tc.configContent), 0644); writeErr != nil {
					t.Fatalf("Write kazi.yml: %v", writeErr)
				}
			}

			// 4) Initialize git repo
			if err := os.Mkdir(filepath.Join(tmpDir, ".git"), 0755); err != nil {
				t.Fatalf("Mkdir .git: %v", err)
			}
			if err := initGitRepo(tmpDir); err != nil {
				t.Fatalf("Failed to initialize git repo: %v", err)
			}

			// 5) We'll call main.Run or replicate the main approach
			// We can replicate the logic used by main() or we can call your code directly.

			// We'll do a direct approach: load config
			cfg, loadErr := config.LoadConfig(cfgPath)
			if loadErr != nil && !tc.wantErr {
				t.Fatalf("LoadConfig error: %v", loadErr)
			} else if loadErr != nil && tc.wantErr {
				t.Logf("Got expected error: %v", loadErr)
				return
			} else if loadErr == nil && tc.wantErr && tc.name == "Missing config file" {
				t.Fatalf("Expected error but got none.")
			}
			if loadErr != nil {
				// we expected error, so test done
				return
			}

			// Update workspace path to be absolute
			if cfg != nil {
				if tc.name == "Non-existent workspace path" {
					cfg.Spec.Global.Workspace = filepath.Join(tmpDir, "no_such_dir")
				} else {
					cfg.Spec.Global.Workspace = tmpDir
				}
			}

			// 6) init AI client or skip if no API key
			aiClient, aiErr := initMockOrRealAI()
			if aiErr != nil && !tc.wantErr {
				t.Fatalf("init AI: %v", aiErr)
			}

			// 7) start LSP or degrade
			lspCli, lspErr := initMockOrRealLSP(tmpDir)
			if lspErr != nil && !tc.wantErr {
				t.Logf("Warning: LSP error, degrade to noop: %v", lspErr)
				lspCli = lsp.NewNoopClient()
			}

			// 8) create the app
			app := NewApp(cfg, aiClient, lspCli)

			// 9) run
			runErr := app.Run()
			if runErr != nil && !tc.wantErr {
				t.Fatalf("app.Run error: %v", runErr)
			} else if runErr == nil && tc.wantErr {
				t.Fatalf("Expected error but got success for test %q", tc.name)
			}

			t.Logf("TestCase %q completed, wantErr=%v, gotErr=%v", tc.name, tc.wantErr, (runErr != nil))
		})
	}
}

// mockAIClient implements ai.LLMClient for testing
type mockAIClient struct{}

func (m *mockAIClient) GetPatch(ctx context.Context, prompt string) (string, error) {
	return `{"patches":[{"file":"main.go","type":"create","content":"package main\n\nfunc main() {}\n"}]}`, nil
}

// initMockOrRealAI returns a mock AI client for testing
func initMockOrRealAI() (ai.LLMClient, error) {
	return &mockAIClient{}, nil
}

// initMockOrRealLSP is a placeholder if you want real gopls or a noop
func initMockOrRealLSP(workspace string) (lsp.LSPClient, error) {
	return lsp.NewGoplsClient(context.Background(), workspace, "gopls", 5*time.Second)
	// or handle errors
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
		{"git", []string{"status"}}, // Debug command
		{"git", []string{"commit", "-m", "Initial commit"}},
	}

	for _, cmd := range cmds {
		c := exec.Command(cmd.name, cmd.args...)
		c.Dir = dir
		output, err := c.CombinedOutput()
		if err != nil {
			return fmt.Errorf("failed to run %s %v: %w\nOutput: %s", cmd.name, cmd.args, err, output)
		}
	}
	return nil
}
