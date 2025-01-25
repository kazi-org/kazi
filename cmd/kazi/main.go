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
	config          *config.KaziProject
	aiClient        ai.LLMClient
	lspClient       gols.LSPClient
	ctxStore        *contextstore.KaziContextStore
	workspace       string
	userInteraction workflow.UserInteraction
}

// Option configures the App
type Option func(*App)

// NewApp creates a new instance of App with the given dependencies.
func NewApp(opts ...Option) *App {
	app := &App{
		userInteraction: workflow.NewDefaultInteraction(),
	}

	for _, opt := range opts {
		opt(app)
	}

	// Validate required fields
	if app.config == nil {
		log.Fatal("config is required")
	}
	if app.aiClient == nil {
		log.Fatal("AI client is required")
	}
	if app.lspClient == nil {
		log.Fatal("LSP client is required")
	}

	// Ensure workspace path is absolute
	absWorkspace, err := filepath.Abs(app.workspace)
	if err != nil {
		log.Fatalf("get absolute workspace path: %v", err)
	}

	// Verify workspace exists
	if _, err := os.Stat(absWorkspace); err != nil {
		log.Fatalf("workspace does not exist: %v", err)
	}

	app.workspace = absWorkspace

	// Initialize context store
	app.ctxStore = contextstore.NewKaziContextStore(absWorkspace, app.lspClient)
	if err := app.ctxStore.BuildOrRefresh(); err != nil {
		log.Fatalf("build context store: %v", err)
	}

	return app
}

// Run executes the main application logic
func (a *App) Run(args []string) error {
	if len(args) > 0 {
		switch args[0] {
		case "--help", "-h":
			fmt.Println("Usage: kazi [options]")
			fmt.Println("Options:")
			fmt.Println("  --help, -h     Show help")
			fmt.Println("  --version, -v  Show version")
			return nil
		case "--version", "-v":
			fmt.Println("kazi version 0.1.0")
			return nil
		default:
			return fmt.Errorf("unknown flag: %s", args[0])
		}
	}

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
		a.userInteraction,
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

	return NewApp(
		WithConfig(cfg),
		WithAI(aiClient),
		WithLSP(lspClient),
		WithWorkspace(cfg.Spec.Global.Workspace),
	), nil
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

	// Run the app
	return app.Run(flag.Args())
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

// WithUserInteraction sets the user interaction interface for the app
func WithUserInteraction(interaction workflow.UserInteraction) Option {
	return func(app *App) {
		app.userInteraction = interaction
	}
}

// WithConfig sets the config for the app
func WithConfig(config *config.KaziProject) Option {
	return func(app *App) {
		app.config = config
	}
}

// WithAI sets the AI client for the app
func WithAI(aiClient ai.LLMClient) Option {
	return func(app *App) {
		app.aiClient = aiClient
	}
}

// WithLSP sets the LSP client for the app
func WithLSP(lspClient gols.LSPClient) Option {
	return func(app *App) {
		app.lspClient = lspClient
	}
}

// WithWorkspace sets the workspace for the app
func WithWorkspace(workspace string) Option {
	return func(app *App) {
		app.workspace = workspace
	}
}
