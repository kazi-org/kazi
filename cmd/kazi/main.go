// cmd/kazi/main.go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/lsp"
	"github.com/kazi-org/kazi/internal/workflow"
)

// App represents the main application and its dependencies.
type App struct {
	config    *config.KaziProject
	aiClient  ai.LLMClient
	lspClient lsp.LSPClient
}

// NewApp creates a new instance of App with the given dependencies.
func NewApp(cfg *config.KaziProject, aiClient ai.LLMClient, lspClient lsp.LSPClient) *App {
	return &App{
		config:    cfg,
		aiClient:  aiClient,
		lspClient: lspClient,
	}
}

// Run executes the main application logic.
func (a *App) Run() error {
	// Validate workspace path exists
	if _, err := os.Stat(a.config.Spec.Global.Workspace); os.IsNotExist(err) {
		return fmt.Errorf("workspace path does not exist: %s", a.config.Spec.Global.Workspace)
	}

	// 1) Create a new KaziContextStore for the workspace.
	store := contextstore.NewKaziContextStore(a.config.Spec.Global.Workspace)

	// 2) Build (or refresh) the code context from the local .go files, ignoring .git, etc.
	if err := store.BuildOrRefresh(); err != nil {
		return fmt.Errorf("failed to build code context: %w", err)
	}

	// 3) Retrieve the CodeContext that we can pass to workflow steps.
	ctxStore := store.GetCodeContext()

	// 4) Process each prompt in our config
	for _, prompt := range a.config.Spec.Prompts {
		err := workflow.ProcessPrompt(
			prompt,
			a.config.Spec.Global,
			a.config.Spec.Rules,
			ctxStore,
			a.aiClient,
		)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Prompt %q failed: %v\n", prompt.Name, err)
			continue
		}
	}

	return nil
}

// main is the CLI entrypoint. We parse flags, load config, spin up LSP, run Kazi.
func main() {
	var configPath string
	flag.StringVar(&configPath, "config", "kazi.yml", "Path to kazi.yml (YAML format) config")
	flag.Parse()

	// 1) Load our KaziProject config
	cfg, err := config.LoadConfig(configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// 2) Initialize the AI client (OpenAI)
	aiClient, err := ai.NewOpenAIClient()
	if err != nil {
		log.Fatalf("Failed to init AI client: %v", err)
	}

	// 3) Start the gopls-based LSP client, or degrade to no-op on error
	var lspCli lsp.LSPClient
	timeout := 5 * time.Second // default timeout
	if cfg.Spec.Global.LanguageServer.Timeout != "" {
		timeout, err = time.ParseDuration(cfg.Spec.Global.LanguageServer.Timeout)
		if err != nil {
			log.Printf("Warning: invalid LSP timeout %q: %v. Using default timeout.", cfg.Spec.Global.LanguageServer.Timeout, err)
			timeout = 5 * time.Second
		}
	}
	lspCli, err = lsp.NewGoplsClient(context.Background(), cfg.Spec.Global.Workspace, timeout)
	if err != nil {
		log.Printf("Warning: could not start gopls: %v. Using no-op LSP client.", err)
		lspCli = lsp.NewNoopClient()
	}
	defer lspCli.Close()

	// 4) Create our main App
	app := NewApp(cfg, aiClient, lspCli)

	// 5) Run the application flow
	if err := app.Run(); err != nil {
		log.Fatalf("Kazi run failed: %v", err)
	}
}
