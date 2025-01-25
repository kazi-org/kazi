// Package main provides the main entry point for the Kazi application.
package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestRun(t *testing.T) {
	tmpDir := t.TempDir()
	err := os.WriteFile(filepath.Join(tmpDir, ".kazi.yaml"), []byte(`
apiVersion: kazi.io/v1
kind: Config
metadata:
  name: test-config
spec:
  global:
    workspace: .
    languageServer:
      name: gopls
      command: gopls
      timeout: 30s
    lintCommand: golangci-lint run
    testCommand: go test ./...
  rules:
    - rule1
    - rule2
  prompts:
    - "Test prompt"
`), 0644)
	assert.NoError(t, err)

	// Change to temp directory
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Failed to get current directory: %v", err)
	}
	defer os.Chdir(origDir)

	err = os.Chdir(tmpDir)
	if err != nil {
		t.Fatalf("Failed to change directory: %v", err)
	}

	// Run the application
	err = run()
	assert.NoError(t, err)
}
