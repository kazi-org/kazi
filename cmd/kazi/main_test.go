// Package main provides the main entry point for the Kazi application.
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

	// Initialize git repo
	err := exec.Command("git", "init", testDir).Run()
	if err != nil {
		t.Fatalf("failed to initialize git repo: %v", err)
	}

	// Change to test directory
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get current directory: %v", err)
	}
	defer os.Chdir(origDir)

	if err := os.Chdir(testDir); err != nil {
		t.Fatalf("failed to change directory: %v", err)
	}

	// Create test config file
	err = os.WriteFile(".kazi.yaml", []byte(`
apiVersion: kazi.io/v1
kind: Config
metadata:
  name: test-config
spec:
  rules:
    - test rule
`), 0644)
	if err != nil {
		t.Fatalf("failed to write config file: %v", err)
	}

	// Run test
	err = run()
	assert.NoError(t, err)
}
