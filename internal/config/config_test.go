package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLoadConfig(t *testing.T) {
	tests := []struct {
		name        string
		content     string
		want        *KaziProject
		wantErr     bool
		errContains string
	}{
		{
			name: "Valid config with defaults",
			content: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: test
spec:
  global:
    workspace: "."
  rules:
    - "Use gofmt for formatting"
  prompts:
    - "add test"`,
			want: &KaziProject{
				APIVersion: "kazi.io/v1",
				Kind:       "KaziProject",
				Metadata: Metadata{
					Name: "test",
				},
				Spec: ProjectSpec{
					Global: GlobalConfig{
						Workspace:   ".",
						LintCommand: "go vet ./...",
						TestCommand: "go test ./...",
						LanguageServer: LanguageServer{
							Timeout: "30s",
						},
					},
					Rules:   []string{"Use gofmt for formatting"},
					Prompts: []string{"add test"},
				},
			},
		},
		{
			name: "Valid config with custom commands",
			content: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: test
spec:
  global:
    workspace: "."
    lintCommand: "golangci-lint run"
    testCommand: "go test -v ./..."
  rules:
    - "Use gofmt for formatting"
  prompts:
    - "add test"
    - "implement validation"`,
			want: &KaziProject{
				APIVersion: "kazi.io/v1",
				Kind:       "KaziProject",
				Metadata: Metadata{
					Name: "test",
				},
				Spec: ProjectSpec{
					Global: GlobalConfig{
						Workspace:   ".",
						LintCommand: "golangci-lint run",
						TestCommand: "go test -v ./...",
						LanguageServer: LanguageServer{
							Timeout: "30s",
						},
					},
					Rules:   []string{"Use gofmt for formatting"},
					Prompts: []string{"add test", "implement validation"},
				},
			},
		},
		{
			name: "Valid config with custom LSP settings",
			content: `apiVersion: kazi.io/v1
kind: KaziProject
metadata:
  name: test
spec:
  global:
    workspace: "."
    lintCommand: "golangci-lint run"
    testCommand: "go test -v ./..."
    languageServer:
      name: "gopls"
      command: "gopls serve"
      timeout: "1m"
  rules:
    - "Use gofmt for formatting"
  prompts:
    - "add test"`,
			want: &KaziProject{
				APIVersion: "kazi.io/v1",
				Kind:       "KaziProject",
				Metadata: Metadata{
					Name: "test",
				},
				Spec: ProjectSpec{
					Global: GlobalConfig{
						Workspace:   ".",
						LintCommand: "golangci-lint run",
						TestCommand: "go test -v ./...",
						LanguageServer: LanguageServer{
							Name:    "gopls",
							Command: "gopls serve",
							Timeout: "1m",
						},
					},
					Rules:   []string{"Use gofmt for formatting"},
					Prompts: []string{"add test"},
				},
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
  name: test
spec:
  global:
    workspace: "."`,
			wantErr:     true,
			errContains: "missing required field: spec.prompts",
		},
		{
			name: "Invalid API version",
			content: `apiVersion: kazi.io/v2
kind: KaziProject
metadata:
  name: test
spec:
  global:
    workspace: "."
  prompts:
    - "test"`,
			wantErr:     true,
			errContains: `invalid API version "kazi.io/v2", expected kazi.io/v1`,
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
				if tc.errContains != "" && !strings.Contains(err.Error(), tc.errContains) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Compare results
			if !reflect.DeepEqual(cfg, tc.want) {
				t.Errorf("LoadConfig() = %+v, want %+v", cfg, tc.want)
			}
		})
	}
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
