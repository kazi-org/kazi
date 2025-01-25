package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type KaziProject struct {
	APIVersion string      `yaml:"apiVersion"`
	Kind       string      `yaml:"kind"`
	Metadata   Metadata    `yaml:"metadata"`
	Spec       ProjectSpec `yaml:"spec"`
}

type Metadata struct {
	Name   string            `yaml:"name"`
	Labels map[string]string `yaml:"labels,omitempty"`
}

type ProjectSpec struct {
	Global  GlobalConfig `yaml:"global"`
	Rules   []string     `yaml:"rules"`
	Prompts []Prompt     `yaml:"prompts"`
}

// GlobalConfig contains global configuration for the project
type GlobalConfig struct {
	Workspace      string         `yaml:"workspace"`
	LintCommand    string         `yaml:"lintCommand"`
	TestCommand    string         `yaml:"testCommand"`
	LanguageServer LanguageServer `yaml:"languageServer"`
}

type LanguageServer struct {
	Name    string `yaml:"name"`
	Command string `yaml:"command"`
	Timeout string `yaml:"timeout,omitempty"` // Duration string like "5s", "1m", etc.
}

type Prompt struct {
	Name         string `yaml:"name"`
	Instructions string `yaml:"instructions"`
}

// LoadConfig loads the configuration from the given file path
func LoadConfig(path string) (*KaziProject, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config file: %w", err)
	}

	var cfg KaziProject
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config file: %w", err)
	}

	// Validate API version
	if cfg.APIVersion != "kazi.io/v1" {
		return nil, fmt.Errorf("invalid API version %q, expected kazi.io/v1", cfg.APIVersion)
	}

	// Validate required fields
	if cfg.Kind == "" {
		return nil, fmt.Errorf("missing required field: kind")
	}
	if cfg.Metadata.Name == "" {
		return nil, fmt.Errorf("missing required field: metadata.name")
	}
	if cfg.Spec.Global.Workspace == "" {
		return nil, fmt.Errorf("missing required field: spec.global.workspace")
	}
	if len(cfg.Spec.Prompts) == 0 {
		return nil, fmt.Errorf("missing required field: spec.prompts")
	}

	// Set default commands if not specified
	if cfg.Spec.Global.LintCommand == "" {
		cfg.Spec.Global.LintCommand = "go vet ./..."
	}
	if cfg.Spec.Global.TestCommand == "" {
		cfg.Spec.Global.TestCommand = "go test ./..."
	}

	// Set default LSP timeout if not specified
	if cfg.Spec.Global.LanguageServer.Timeout == "" {
		cfg.Spec.Global.LanguageServer.Timeout = "30s"
	}

	return &cfg, nil
}
