// Package main provides the CLI entry point for Kazi.
// In a real application, you'd parse subcommands (like "prompt") and
// initialize core components (project, coordinator, etc.).

package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: kazi <command> [args]")
		os.Exit(1)
	}

	subcommand := os.Args[1]
	switch subcommand {
	case "prompt":
		// Example: kazi prompt "Implement feature X"
		fmt.Println("Prompt subcommand not implemented. See coordinator logic.")
	default:
		fmt.Printf("Unknown subcommand: %s\n", subcommand)
	}
}
