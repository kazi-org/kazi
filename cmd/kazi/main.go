// Package main provides the main entry point for the Kazi application.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/kazi-org/kazi/internal/workflow"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// Get workspace directory
	wd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("get working directory: %w", err)
	}

	// Check if stdin has data
	stat, err := os.Stdin.Stat()
	if err != nil {
		return fmt.Errorf("check stdin: %w", err)
	}

	var cfg *config.KaziProject
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

	// Create prompt
	prompt := "test"

	// Process prompt
	result, err := workflow.Process(ctx, codeCtx, prompt, cfg.Spec.Rules, cfg.Spec.Global)
	if err != nil {
		return fmt.Errorf("failed to process workflow: %w", err)
	}

	fmt.Println(result)
	return nil
}
