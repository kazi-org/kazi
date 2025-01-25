// Package main implements the Kazi CLI tool for AI-assisted code generation and modification.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/workflow"
)

// App represents the main application and its dependencies.
// It encapsulates all the components needed to run the Kazi tool.
type App struct {
	config   *config.KaziProject
	aiClient ai.LLMClient
}

// NewApp creates a new instance of App with the given dependencies.
// It validates the input parameters to ensure they are not nil.
func NewApp(cfg *config.KaziProject, aiClient ai.LLMClient) (*App, error) {
	if cfg == nil {
		return nil, fmt.Errorf("config cannot be nil")
	}
	if aiClient == nil {
		return nil, fmt.Errorf("AI client cannot be nil")
	}

	return &App{
		config:   cfg,
		aiClient: aiClient,
	}, nil
}

// Run executes the main application logic.
// It processes each prompt in the configuration, building context and applying changes.
func (a *App) Run() error {
	// Ensure workspace path is absolute
	absWorkspace, err := filepath.Abs(a.config.Spec.Global.Workspace)
	if err != nil {
		return fmt.Errorf("failed to get absolute workspace path: %w", err)
	}
	a.config.Spec.Global.Workspace = absWorkspace

	// Validate workspace path exists
	if _, err := os.Stat(absWorkspace); os.IsNotExist(err) {
		return fmt.Errorf("workspace path does not exist: %s", absWorkspace)
	}

	// Create and initialize the context store
	store := contextstore.NewKaziContextStore(absWorkspace)
	if err := store.BuildOrRefresh(); err != nil {
		return fmt.Errorf("failed to build code context: %w", err)
	}

	// Process each prompt in the configuration
	ctxStore := store.GetCodeContext()
	for _, prompt := range a.config.Spec.Prompts {
		if err := a.processPrompt(prompt, ctxStore); err != nil {
			return err
		}
	}

	return nil
}

// processPrompt handles a single prompt, applying the workflow steps.
// It encapsulates the prompt processing logic for better error handling and readability.
func (a *App) processPrompt(prompt config.Prompt, ctxStore *contextstore.CodeContext) error {
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
		ctxStore,
		a.aiClient,
	)
	if err != nil {
		return fmt.Errorf("prompt %q failed: %w", prompt.Name, err)
	}

	return nil
}

// initApp initializes the application with all its dependencies.
// It handles configuration loading and AI client initialization.
func initApp(configPath string) (*App, error) {
	// Ensure config path is absolute
	absConfigPath, err := filepath.Abs(configPath)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute config path: %w", err)
	}

	// Load and validate configuration
	cfg, err := config.LoadConfig(absConfigPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load config from %s: %w", absConfigPath, err)
	}

	// Initialize the AI client
	aiClient, err := ai.NewOpenAIClient()
	if err != nil {
		return nil, fmt.Errorf("failed to initialize AI client: %w", err)
	}

	// Create and validate the application instance
	return NewApp(cfg, aiClient)
}

// run is the main entry point for the application logic.
// It handles command-line flags and initializes the application.
func run() error {
	var configPath string
	flag.StringVar(&configPath, "config", "kazi.yml", "Path to kazi.yml (YAML format) config file")
	flag.Parse()

	app, err := initApp(configPath)
	if err != nil {
		return fmt.Errorf("initialization failed: %w", err)
	}

	if err := app.Run(); err != nil {
		return fmt.Errorf("application error: %w", err)
	}

	return nil
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
