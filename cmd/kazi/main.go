// Package main provides the main entry point for the Kazi application.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/go-git/go-git/v5"
	"github.com/kazi-org/kazi/internal/ai/openai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/workflow"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func applyPatch(chunk *patch.Chunk) error {
	switch chunk.Type {
	case patch.PatchCreate:
		// Create new file
		if err := os.WriteFile(chunk.File, []byte(chunk.Content), 0644); err != nil {
			return fmt.Errorf("create file %s: %w", chunk.File, err)
		}
		fmt.Printf("Created file: %s\n", chunk.File)

	case patch.PatchReplace:
		// Read existing file
		content, err := os.ReadFile(chunk.File)
		if err != nil {
			return fmt.Errorf("read file %s: %w", chunk.File, err)
		}

		lines := strings.Split(string(content), "\n")
		if chunk.FromLine < 1 || chunk.FromLine > len(lines) ||
			chunk.ToLine < chunk.FromLine || chunk.ToLine > len(lines) {
			return fmt.Errorf("invalid line range %d-%d for file %s", chunk.FromLine, chunk.ToLine, chunk.File)
		}

		// Build the new content
		var result []string

		// Add lines before the change
		result = append(result, lines[:chunk.FromLine-1]...)

		// Add context before if provided
		if len(chunk.ContextBefore) > 0 {
			// Verify context matches
			contextStart := max(0, chunk.FromLine-len(chunk.ContextBefore)-1)
			actualContext := lines[contextStart : chunk.FromLine-1]
			if !matchContext(actualContext, chunk.ContextBefore) {
				return fmt.Errorf("context before doesn't match in file %s", chunk.File)
			}
		}

		// Add the new content
		result = append(result, strings.Split(chunk.Content, "\n")...)

		// Add context after if provided
		if len(chunk.ContextAfter) > 0 {
			// Verify context matches
			contextEnd := min(len(lines), chunk.ToLine+len(chunk.ContextAfter))
			actualContext := lines[chunk.ToLine:contextEnd]
			if !matchContext(actualContext, chunk.ContextAfter) {
				return fmt.Errorf("context after doesn't match in file %s", chunk.File)
			}
		}

		// Add remaining lines
		result = append(result, lines[chunk.ToLine:]...)

		// Write back to file
		if err := os.WriteFile(chunk.File, []byte(strings.Join(result, "\n")), 0644); err != nil {
			return fmt.Errorf("write file %s: %w", chunk.File, err)
		}
		fmt.Printf("Modified file: %s\n", chunk.File)

	case patch.PatchDelete:
		// Delete file
		if err := os.Remove(chunk.File); err != nil {
			return fmt.Errorf("delete file %s: %w", chunk.File, err)
		}
		fmt.Printf("Deleted file: %s\n", chunk.File)

	default:
		return fmt.Errorf("unknown patch type: %s", chunk.Type)
	}

	return nil
}

func matchContext(actual []string, expected []string) bool {
	if len(actual) != len(expected) {
		return false
	}
	for i := range actual {
		if actual[i] != expected[i] {
			return false
		}
	}
	return true
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// mockGitCommitter implements workflow.GitCommitter interface
type mockGitCommitter struct {
	workspace string
}

func (m *mockGitCommitter) Commit(ctx context.Context, message string) error {
	fmt.Printf("Would commit changes with message: %s\n", message)
	return nil
}

func (m *mockGitCommitter) Status(ctx context.Context) (git.Status, error) {
	return nil, nil
}

// mockValidator implements workflow.Validator interface
type mockValidator struct {
	config config.GlobalConfig
}

func (m *mockValidator) Validate(ctx context.Context) error {
	fmt.Printf("Would run: %s\n", m.config.LintCommand)
	fmt.Printf("Would run: %s\n", m.config.TestCommand)
	return nil
}

func run() error {
	// Get workspace directory
	wd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("get working directory: %w", err)
	}

	var cfg *config.KaziProject

	// Check for command line arguments first
	if len(os.Args) > 1 {
		// Use the first argument as the prompt
		cfg = config.DefaultConfig(os.Args[1])
	} else {
		// Check if stdin has data
		stat, err := os.Stdin.Stat()
		if err != nil {
			return fmt.Errorf("check stdin: %w", err)
		}

		if (stat.Mode() & os.ModeCharDevice) == 0 {
			// Data is being piped to stdin
			cfg, err = config.LoadConfigFromReader(os.Stdin)
			if err != nil {
				return fmt.Errorf("load config from stdin: %w", err)
			}
		} else {
			// No stdin data, try loading from file
			cfg, err = config.LoadConfig(filepath.Join(wd, ".kazi.yaml"))
			if err != nil {
				return fmt.Errorf("load config from file: %w", err)
			}
		}
	}

	// Initialize LSP client
	lspClient, err := gols.NewGoClient(context.Background(), cfg.Spec.Global.Workspace)
	if err != nil {
		return fmt.Errorf("create LSP client: %w", err)
	}
	defer lspClient.Close()

	// Initialize context store
	store := contextstore.NewKaziContextStore(contextstore.StoreConfig{
		Workspace:    cfg.Spec.Global.Workspace,
		ScanInterval: 30,
		LSPClient:    lspClient,
	})

	// Build or refresh code context
	ctx := context.Background()
	if err := store.BuildOrRefresh(ctx); err != nil {
		return fmt.Errorf("build code context: %w", err)
	}

	// Get code context
	codeCtx := store.GetCodeContext()
	if codeCtx == nil {
		return fmt.Errorf("failed to get code context")
	}

	// Use the first prompt from the config
	prompt := cfg.Spec.Prompts[0]

	// Create OpenAI client
	llmClient, err := openai.NewClient()
	if err != nil {
		return fmt.Errorf("create OpenAI client: %w", err)
	}

	// Create processor configuration
	procCfg := &workflow.ProcessorConfig{
		GitCommitter:    &mockGitCommitter{workspace: cfg.Spec.Global.Workspace},
		Validator:       &mockValidator{config: cfg.Spec.Global},
		RequestBuilder:  workflow.NewRequestBuilderWithConfig(codeCtx, cfg.Spec.Rules, workflow.NewConfigFromGlobal(cfg.Spec.Global, cfg.Spec.Rules)),
		PatchApplier:    patch.NewApplier(cfg.Spec.Global.Workspace),
		UserInteraction: workflow.NewDefaultInteraction(),
		LLMClient:       llmClient,
	}

	// Create and run processor
	proc, err := workflow.NewProcessor(procCfg)
	if err != nil {
		return fmt.Errorf("create processor: %w", err)
	}

	// Process the prompt
	if err := proc.Process(ctx, prompt); err != nil {
		return fmt.Errorf("process prompt: %w", err)
	}

	return nil
}
