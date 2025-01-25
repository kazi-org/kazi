// Package main provides the main entry point for the Kazi application.
package main

import (
	"context"
	"encoding/json"
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

	// Process prompt
	response, err := workflow.Process(ctx, codeCtx, prompt, cfg.Spec.Rules, cfg.Spec.Global)
	if err != nil {
		return fmt.Errorf("failed to process workflow: %w", err)
	}

	// Parse and apply patches
	var patches struct {
		Patches []struct {
			File    string `json:"file"`
			Type    string `json:"type"`
			Content string `json:"content"`
		} `json:"patches"`
	}
	if err := json.Unmarshal([]byte(response), &patches); err != nil {
		return fmt.Errorf("parse patches: %w", err)
	}

	// Apply patches
	for _, p := range patches.Patches {
		switch p.Type {
		case "create":
			// Create new file
			if err := os.WriteFile(p.File, []byte(p.Content), 0644); err != nil {
				return fmt.Errorf("create file %s: %w", p.File, err)
			}
			fmt.Printf("Created file: %s\n", p.File)
		case "modify":
			// Modify existing file
			if err := os.WriteFile(p.File, []byte(p.Content), 0644); err != nil {
				return fmt.Errorf("modify file %s: %w", p.File, err)
			}
			fmt.Printf("Modified file: %s\n", p.File)
		case "delete":
			// Delete file
			if err := os.Remove(p.File); err != nil {
				return fmt.Errorf("delete file %s: %w", p.File, err)
			}
			fmt.Printf("Deleted file: %s\n", p.File)
		default:
			return fmt.Errorf("unknown patch type: %s", p.Type)
		}
	}

	return nil
}
