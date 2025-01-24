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
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config file: %w", err)
	}
	var cfg KaziProject
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("unmarshal YAML: %w", err)
	}
	return &cfg, nil
}
