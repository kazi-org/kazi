package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kazi-org/kazi/internal/config"
	lsp "github.com/kazi-org/kazi/internal/lsp/go"
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
	if err := initGitRepo(tmpDir); err != nil {
		cleanup()
		t.Fatalf("Failed to initialize git repo: %v", err)
	}

	return tmpDir, cleanup
}

// mockLSPClient implements lsp.LSPClient for testing
type mockLSPClient struct{}

func (m *mockLSPClient) GetWorkspaceSymbols(query string) ([]lsp.WorkspaceSymbol, error) {
	return []lsp.WorkspaceSymbol{}, nil
}

func (m *mockLSPClient) GetSymbolDocumentation(file, symbol string) (string, error) {
	return "", nil
}

func (m *mockLSPClient) GetReferences(symbol string) ([]string, error) {
	return nil, nil
}

func (m *mockLSPClient) GetSymbolDefinition(file, symbol string) (*lsp.SymbolDefinition, error) {
	return nil, nil
}

func (m *mockLSPClient) GetFileContent(file string) (string, error) {
	return "package main\n\nfunc main() {}\n", nil
}

func (m *mockLSPClient) GetSymbolLocation(file, symbol string) (lsp.Location, error) {
	return lsp.Location{}, nil
}

func (m *mockLSPClient) CheckCode(code string) (bool, string) {
	// For testing, we'll consider any code that starts with "package" as valid
	if strings.HasPrefix(strings.TrimSpace(code), "package") {
		return true, ""
	}
	return false, "invalid Go code"
}

func (m *mockLSPClient) Close() error {
	return nil
}

// mockNewGoClient returns a mock LSP client for testing
func mockNewGoClient(ctx context.Context, workspace string) (lsp.LSPClient, error) {
	return &mockLSPClient{}, nil
}

// mockAIClient implements ai.LLMClient for testing
type mockAIClient struct{}

func (m *mockAIClient) GetPatch(ctx context.Context, prompt string) (string, error) {
	return `{
		"patches": [
			{
				"file": "main_test.go",
				"type": "create",
				"content": "package main\n\nimport \"testing\"\n\nfunc TestGreet(t *testing.T) {\n\tgot := Greet(\"World\")\n\twant := \"Hello, World!\"\n\tif got != want {\n\t\tt.Errorf(\"Greet(\\\"World\\\") = %q, want %q\", got, want)\n\t}\n}\n"
			}
		],
		"commit": {
			"subject": "Add test for Greet function",
			"body": "Added a test case to verify the Greet function returns the expected greeting message."
		}
	}`, nil
}

func TestKaziIntegration(t *testing.T) {
	// Save original NewGoClient function and restore it after test
	originalNewGoClient := lsp.NewGoClient
	defer func() { lsp.NewGoClient = originalNewGoClient }()
	lsp.NewGoClient = mockNewGoClient

	// Create temporary workspace
	tmpDir, err := os.MkdirTemp("", "kazi-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Initialize Go module
	cmd := exec.Command("go", "mod", "init", "example.com/test")
	cmd.Dir = tmpDir
	if err := cmd.Run(); err != nil {
		t.Fatalf("Failed to initialize Go module: %v", err)
	}

	// Download dependencies
	cmd = exec.Command("go", "mod", "tidy")
	cmd.Dir = tmpDir
	if err := cmd.Run(); err != nil {
		t.Fatalf("Failed to download dependencies: %v", err)
	}

	// Create test file
	testFile := filepath.Join(tmpDir, "main.go")
	err = os.WriteFile(testFile, []byte(`package main

import (
	"fmt"
)

// Greet returns a greeting message
func Greet(name string) string {
	return fmt.Sprintf("Hello, %s!", name)
}

func main() {
	fmt.Println(Greet("World"))
}
`), 0644)
	if err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}

	// Create config file
	configPath := filepath.Join(tmpDir, "kazi.yaml")
	err = os.WriteFile(configPath, []byte(`apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: test-project
spec:
  global:
    workspace: "`+tmpDir+`"
    lintCommand: "go vet ./..."
    testCommand: "go test ./..."
    languageServer:
      name: gopls
      command: gopls
      timeout: 30s
  rules:
    - "We use snake_case"
  prompts:
    - name: test
      instructions: "add test"
`), 0644)
	if err != nil {
		t.Fatalf("Failed to write config file: %v", err)
	}

	// Initialize git repository
	if err := initGitRepo(tmpDir); err != nil {
		t.Fatalf("Failed to initialize git repo: %v", err)
	}

	// Set config path flag
	oldArgs := os.Args
	defer func() { os.Args = oldArgs }()
	os.Args = []string{"kazi", "-config", configPath}
	flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ExitOnError)

	// Load config
	cfg, err := config.LoadConfig(configPath)
	if err != nil {
		t.Fatalf("Failed to load config: %v", err)
	}

	// Create LSP client
	lspClient, err := lsp.NewGoClient(context.Background(), tmpDir)
	if err != nil {
		t.Fatalf("Failed to create LSP client: %v", err)
	}

	// Run test with mock AI client
	app, err := NewApp(cfg, &mockAIClient{}, lspClient, tmpDir)
	if err != nil {
		t.Fatalf("Failed to create app: %v", err)
	}

	if err := app.Run(); err != nil {
		t.Fatalf("Failed to run app: %v", err)
	}
}

// initGitRepo initializes a git repository in the given directory
func initGitRepo(dir string) error {
	// Remove existing .git directory if it exists
	if err := os.RemoveAll(filepath.Join(dir, ".git")); err != nil {
		return fmt.Errorf("failed to remove existing .git directory: %w", err)
	}

	// Initialize repository
	cmd := exec.Command("git", "init")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to initialize git repo: %s: %w", string(out), err)
	}

	// Configure git user
	cmds := []struct {
		args []string
		env  []string
	}{
		{
			args: []string{"config", "user.email", "test@example.com"},
			env:  []string{"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null"},
		},
		{
			args: []string{"config", "user.name", "Test User"},
			env:  []string{"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null"},
		},
		{
			args: []string{"add", "."},
			env:  nil,
		},
		{
			args: []string{"commit", "-m", "Initial commit"},
			env:  []string{"GIT_AUTHOR_DATE=2024-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2024-01-01T00:00:00Z"},
		},
	}

	for _, c := range cmds {
		cmd := exec.Command("git", c.args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), c.env...)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to run git %v: %s: %w", c.args, string(out), err)
		}
	}

	return nil
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
