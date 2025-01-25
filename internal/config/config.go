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
	Global  GlobalConfig      `yaml:"global"`
	Rules   map[string]string `yaml:"rules"`
	Prompts []Prompt          `yaml:"prompts"`
}

type GlobalConfig struct {
	Workspace      string         `yaml:"workspace"`
	LanguageServer LanguageServer `yaml:"languageServer"`
	BuildCommand   string         `yaml:"buildCommand"`
	TestCommand    string         `yaml:"testCommand"`
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

func LoadConfig(path string) (*KaziProject, error) {
	// Read config file
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config file: %w", err)
	}

	// Parse YAML
	var cfg KaziProject
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config file: %w", err)
	}

	// Validate API version
	if cfg.APIVersion != "kazi.io/v1" {
		return nil, fmt.Errorf("unsupported API version: %s", cfg.APIVersion)
	}

	// Validate required fields
	if cfg.Kind != "KaziProject" {
		return nil, fmt.Errorf("invalid kind: %s", cfg.Kind)
	}
	if cfg.Metadata.Name == "" {
		return nil, fmt.Errorf("missing required field: metadata.name")
	}
	if cfg.Spec.Global.Workspace == "" {
		return nil, fmt.Errorf("missing required field: spec.global.workspace")
	}
	if len(cfg.Spec.Prompts) == 0 {
		return nil, fmt.Errorf("missing required field: prompts")
	}
	for i, p := range cfg.Spec.Prompts {
		if p.Name == "" {
			return nil, fmt.Errorf("missing required field: prompts[%d].name", i)
		}
		if p.Instructions == "" {
			return nil, fmt.Errorf("missing required field: prompts[%d].instructions", i)
		}
	}

	return &cfg, nil
}
