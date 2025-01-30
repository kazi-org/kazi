// Package main provides a minimal CLI entry point for the Kazi system.
// In a real project, you would parse arguments and initialize the coordinator
// with the config, vision, architecture, etc., then call `ProcessPrompt()` or
// any other subcommands like "plan", "build", "test", etc.

package main

import (
	"fmt"
	"os"
	// "github.com/yourorg/kazi/internal/config"
	// "github.com/yourorg/kazi/internal/coordinator"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: kazi <command> [args]")
		os.Exit(1)
	}
	subcommand := os.Args[1]

	switch subcommand {
	case "prompt":
		// e.g. handle "kazi prompt 'Implement X feature'"
		fmt.Println("Prompt subcommand not yet implemented.")
	default:
		fmt.Printf("Unknown subcommand: %s\n", subcommand)
	}
}
