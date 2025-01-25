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
	gols "github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/workflow"
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

// mockLSPClient implements gols.LSPClient for testing
type mockLSPClient struct{}

func (m *mockLSPClient) GetWorkspaceSymbols(query string) ([]gols.WorkspaceSymbol, error) {
	return []gols.WorkspaceSymbol{}, nil
}

func (m *mockLSPClient) GetSymbolDocumentation(file, symbol string) (string, error) {
	return "", nil
}

func (m *mockLSPClient) GetReferences(symbol string) ([]string, error) {
	return nil, nil
}

func (m *mockLSPClient) GetSymbolDefinition(file, symbol string) (*gols.SymbolDefinition, error) {
	return nil, nil
}

func (m *mockLSPClient) GetFileContent(file string) (string, error) {
	return "package main\n\nfunc main() {}\n", nil
}

func (m *mockLSPClient) GetSymbolLocation(file, symbol string) (gols.Location, error) {
	return gols.Location{}, nil
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
func mockNewGoClient(ctx context.Context, workspace string) (gols.LSPClient, error) {
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

// mockInteraction implements workflow.UserInteraction for testing
type mockInteraction struct {
	responses []string
	index     int
}

func newMockInteraction(responses []string) *mockInteraction {
	return &mockInteraction{
		responses: responses,
	}
}

func (m *mockInteraction) PromptForChanges(ctx context.Context, changes *patch.PatchSet) (workflow.UserInteractionMode, *config.Prompt, error) {
	if m.index >= len(m.responses) {
		return workflow.ModeAbort, nil, nil
	}

	response := m.responses[m.index]
	m.index++

	switch response {
	case "yes", "y":
		return workflow.ModeYes, nil, nil
	case "no", "n":
		return workflow.ModeNo, nil, nil
	case "chat", "c":
		return workflow.ModeChat, &config.Prompt{Instructions: "modified prompt"}, nil
	case "abort", "a":
		return workflow.ModeAbort, nil, nil
	case "all":
		return workflow.ModeAll, nil, nil
	case "yolo":
		return workflow.ModeYolo, nil, nil
	default:
		return workflow.ModeAbort, nil, nil
	}
}

func TestKaziIntegration(t *testing.T) {
	// Create mock dependencies
	mockConfig := &config.KaziProject{
		APIVersion: "kazi.io/v1",
		Kind:       "KaziProject",
		Metadata: config.Metadata{
			Name: "test-project",
		},
		Spec: config.ProjectSpec{
			Global: config.GlobalConfig{
				Workspace: ".",
				LanguageServer: config.LanguageServer{
					Name:    "gopls",
					Command: "gopls",
					Timeout: "30s",
				},
			},
			Rules: []string{"Use gofmt for formatting"},
			Prompts: []config.Prompt{
				{
					Name:         "test",
					Instructions: "add test",
				},
			},
		},
	}
	mockAI := &mockAIClient{}
	mockLSP := &mockLSPClient{}

	tests := []struct {
		name      string
		args      []string
		responses []string
		wantErr   bool
	}{
		{
			name:      "help",
			args:      []string{"--help"},
			responses: []string{"yes"},
			wantErr:   false,
		},
		{
			name:      "version",
			args:      []string{"--version"},
			responses: []string{"yes"},
			wantErr:   false,
		},
		{
			name:      "invalid flag",
			args:      []string{"--invalid"},
			responses: []string{"yes"},
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			interaction := newMockInteraction(tt.responses)
			app := NewApp(
				WithConfig(mockConfig),
				WithAI(mockAI),
				WithLSP(mockLSP),
				WithWorkspace("."),
				WithUserInteraction(interaction),
			)
			err := app.Run(tt.args)
			if (err != nil) != tt.wantErr {
				t.Errorf("Run() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
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
