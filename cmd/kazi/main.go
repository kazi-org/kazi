// Package main provides a minimal CLI with subcommands:
//   kazi init
//   kazi build
//   kazi deploy
//   kazi prompt "..." 
// Implementation is left as placeholders.

package main

import (
	"fmt"
	"os"
)

func usage() {
	fmt.Println(`kazi final - usage:
  kazi init
  kazi build
  kazi deploy
  kazi prompt "..."`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	subcommand := os.Args[1]
	switch subcommand {
	case "init":
		fmt.Println("[INIT] placeholder")
	case "build":
		fmt.Println("[BUILD] placeholder")
	case "deploy":
		fmt.Println("[DEPLOY] placeholder")
	case "prompt":
		fmt.Println("[PROMPT] placeholder")
	default:
		fmt.Printf("unknown subcommand: %s\n", subcommand)
		usage()
	}
}
