package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadConfig(t *testing.T) {
	tests := []struct {
		name          string
		content       string
		wantErr       bool
		errContains   string
		validateField func(*testing.T, *KaziProject)
	}{
		{
			name: "Valid minimal config",
			content: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: test-project
spec:
  global:
    workspace: "."
    buildCommand: "go build"
    testCommand: "go test"
  rules:
    - "Use gofmt for formatting"
    - "Write tests for all functions"
  prompts:
    - name: "test"
      instructions: "add test"`,
			wantErr: false,
			validateField: func(t *testing.T, cfg *KaziProject) {
				if cfg.Metadata.Name != "test-project" {
					t.Errorf("expected name 'test-project', got %q", cfg.Metadata.Name)
				}
				if cfg.Spec.Global.BuildCommand != "go build" {
					t.Errorf("expected build command 'go build', got %q", cfg.Spec.Global.BuildCommand)
				}
				if len(cfg.Spec.Prompts) != 1 {
					t.Errorf("expected 1 prompt, got %d", len(cfg.Spec.Prompts))
				}
			},
		},
		{
			name:        "Invalid YAML",
			content:     "invalid: [yaml: content",
			wantErr:     true,
			errContains: "yaml",
		},
		{
			name: "Missing required fields",
			content: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: test-project
spec:
  global:
    workspace: "."
    buildCommand: "go build"
    testCommand: "go test"
  rules:
    - "Use gofmt for formatting"
    - "Write tests for all functions"`,
			wantErr:     true,
			errContains: "missing required field: prompts",
		},
		{
			name: "Invalid API version",
			content: `apiVersion: kazi.io/v2
kind: KaziProject
metadata:
  name: test-project
spec:
  global:
    workspace: "."
    buildCommand: "go build"
    testCommand: "go test"
  prompts:
    - name: "test"
      instructions: "add test"`,
			wantErr:     true,
			errContains: "unsupported API version: kazi.io/v2",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create temporary config file
			tmpDir, err := os.MkdirTemp("", "kazi-config-test-*")
			if err != nil {
				t.Fatalf("Failed to create temp dir: %v", err)
			}
			defer os.RemoveAll(tmpDir)

			configPath := filepath.Join(tmpDir, "kazi.yml")
			if err := os.WriteFile(configPath, []byte(tc.content), 0644); err != nil {
				t.Fatalf("Failed to write config file: %v", err)
			}

			// Test LoadConfig
			cfg, err := LoadConfig(configPath)
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error but got nil")
				}
				if tc.errContains != "" && !contains(err.Error(), tc.errContains) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Validate fields if provided
			if tc.validateField != nil {
				tc.validateField(t, cfg)
			}
		})
	}
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
