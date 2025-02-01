// Package main provides the CLI entry point for Kazi.
// Subcommands: init, build, deploy, prompt "..."
//
// Single responsibility: parse arguments, route subcommands to internal logic.
package main

import (
	"fmt"
	"os"
)

func usage() {
	fmt.Println(`kazi - usage:
  kazi init
  kazi build
  kazi deploy
  kazi prompt "Implement X"
`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	subcommand := os.Args[1]
	switch subcommand {
	case "init":
		fmt.Println("[INIT] placeholder logic, calls project manager or doc references")
	case "build":
		fmt.Println("[BUILD] placeholder logic, calls validator pipeline")
	case "deploy":
		fmt.Println("[DEPLOY] placeholder logic, integrate deployment approach")
	case "prompt":
		fmt.Println("[PROMPT] placeholder logic, orchestrates AI-driven patch flow")
	default:
		fmt.Printf("Unknown subcommand: %s\n", subcommand)
		usage()
	}
}
