package main

import (
	"os"
	"os/exec"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestRun(t *testing.T) {
	// Create test directory
	testDir := t.TempDir()

	// Save original directory
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get current directory: %v", err)
	}

	// Change to test directory
	if err := os.Chdir(testDir); err != nil {
		t.Fatalf("failed to change directory: %v", err)
	}

	// Cleanup
	defer func() {
		os.Chdir(origDir)
	}()

	// Initialize git repo
	err = exec.Command("git", "init", testDir).Run()
	if err != nil {
		t.Fatalf("failed to initialize git repo: %v", err)
	}

	// Create test file
	err = os.WriteFile("main.go", []byte(`package main

func main() {
	println("Hello, World!")
}
`), 0644)
	assert.NoError(t, err)

	// Create test config
	err = os.WriteFile(".kazi.yaml", []byte(`apiVersion: kazi.io/v1
kind: Config
metadata:
  name: test-config
spec:
  rules:
    - test rule
`), 0644)
	assert.NoError(t, err)

	// Run the command
	err = run()
	assert.NoError(t, err)
}
