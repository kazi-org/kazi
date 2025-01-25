// Package main implements the Kazi CLI tool for AI-assisted code generation and modification.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/ai/openai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	gols "github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/kazi-org/kazi/internal/workflow"
)

// App represents the main application and its dependencies.
// It encapsulates all the components needed to run the Kazi tool.
type App struct {
	config    *config.KaziProject
	aiClient  ai.LLMClient
	lspClient gols.LSPClient
	ctxStore  *contextstore.KaziContextStore
	workspace string
}

// NewApp creates a new instance of App with the given dependencies.
// It validates the input parameters to ensure they are not nil.
func NewApp(cfg *config.KaziProject, aiClient ai.LLMClient, lspClient gols.LSPClient, workspace string) (*App, error) {
	if cfg == nil {
		return nil, fmt.Errorf("config is nil")
	}
	if aiClient == nil {
		return nil, fmt.Errorf("AI client is nil")
	}
	if lspClient == nil {
		return nil, fmt.Errorf("LSP client is nil")
	}

	// Ensure workspace path is absolute
	absWorkspace, err := filepath.Abs(workspace)
	if err != nil {
		return nil, fmt.Errorf("get absolute workspace path: %w", err)
	}

	// Verify workspace exists
	if _, err := os.Stat(absWorkspace); err != nil {
		return nil, fmt.Errorf("workspace does not exist: %w", err)
	}

	ctxStore := contextstore.NewKaziContextStore(absWorkspace, lspClient)
	if err := ctxStore.BuildOrRefresh(); err != nil {
		return nil, fmt.Errorf("build context store: %w", err)
	}

	return &App{
		config:    cfg,
		aiClient:  aiClient,
		lspClient: lspClient,
		ctxStore:  ctxStore,
		workspace: absWorkspace,
	}, nil
}

// Run executes the main application logic.
// It processes each prompt in the configuration, building context and applying changes.
func (a *App) Run() error {
	// Process each prompt in the configuration
	for _, prompt := range a.config.Spec.Prompts {
		if err := a.processPrompt(prompt); err != nil {
			return err
		}
	}

	return nil
}

// processPrompt handles a single prompt, applying the workflow steps.
// It encapsulates the prompt processing logic for better error handling and readability.
func (a *App) processPrompt(prompt config.Prompt) error {
	if prompt.Name == "" {
		return fmt.Errorf("prompt name cannot be empty")
	}
	if prompt.Instructions == "" {
		return fmt.Errorf("prompt instructions cannot be empty for prompt %q", prompt.Name)
	}

	fmt.Printf("\nProcessing prompt: %s\n", prompt.Name)
	err := workflow.ProcessPrompt(
		prompt,
		a.config.Spec.Global,
		a.config.Spec.Rules,
		a.ctxStore.GetCodeContext(),
		a.aiClient,
	)
	if err != nil {
		return fmt.Errorf("prompt %q failed: %w", prompt.Name, err)
	}

	return nil
}

// initApp initializes the application with all its dependencies.
// It handles configuration loading and AI client initialization.
func initApp(ctx context.Context, configPath string) (*App, error) {
	// Ensure config path is absolute
	absConfigPath, err := filepath.Abs(configPath)
	if err != nil {
		return nil, fmt.Errorf("get absolute config path: %w", err)
	}

	// Load config
	cfg, err := config.LoadConfig(absConfigPath)
	if err != nil {
		return nil, fmt.Errorf("load config: %w", err)
	}

	// Initialize AI client
	aiClient, err := openai.NewClient()
	if err != nil {
		return nil, fmt.Errorf("init AI client: %w", err)
	}

	// Initialize LSP client
	lspClient, err := gols.NewGoClient(ctx, cfg.Spec.Global.Workspace)
	if err != nil {
		return nil, fmt.Errorf("init LSP client: %w", err)
	}

	return NewApp(cfg, aiClient, lspClient, cfg.Spec.Global.Workspace)
}

// run is the main entry point for the application logic.
// It handles command-line flags and initializes the application.
func run() error {
	// Parse flags
	configPath := flag.String("config", "kazi.yaml", "path to config file")
	flag.Parse()

	// Initialize app
	ctx := context.Background()
	app, err := initApp(ctx, *configPath)
	if err != nil {
		return fmt.Errorf("init app: %w", err)
	}
	defer app.lspClient.Close()

	// Process each prompt
	for _, prompt := range app.config.Spec.Prompts {
		if err := workflow.ProcessPrompt(prompt, app.config.Spec.Global, app.config.Spec.Rules, app.ctxStore.GetCodeContext(), app.aiClient); err != nil {
			return fmt.Errorf("process prompt %q: %w", prompt.Name, err)
		}
	}

	return nil
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
