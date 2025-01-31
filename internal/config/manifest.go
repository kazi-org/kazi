// internal/config/manifest.go
//
// Package config manages the Kubernetes-style manifest that holds the operational
// configuration and vision for the Kazi project.
//
// Example manifest (.kazi.yaml):
//   apiVersion: kazi.bot/v1
//   kind: Project
//   metadata:
//     name: my-project
//   spec:
//     config:
//       workspace: "/path/to/project"
//       lintCommand: "go vet ./..."
//       testCommand: "go test ./..."
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Project represents the top-level structure of the Kazi configuration manifest.
type Project struct {
	APIVersion string   `yaml:"apiVersion"`
	Kind       string   `yaml:"kind"`
	Metadata   Metadata `yaml:"metadata"`
	Spec       Spec     `yaml:"spec"`
}

// Metadata holds standard Kubernetes-style metadata.
type Metadata struct {
	Name   string            `yaml:"name"`
	Labels map[string]string `yaml:"labels,omitempty"`
}

// Spec merges the Vision Contract and operational configuration.
type Spec struct {
	Config Config `yaml:"config"`
}

// Config contains operational details such as workspace and commands for linting/testing.
type Config struct {
	Workspace   string `yaml:"workspace"`
	LintCommand string `yaml:"lintCommand"`
	TestCommand string `yaml:"testCommand"`
}

// LoadManifest reads a .kazi.yaml manifest file and decodes it into a Project structure.
func LoadManifest(path string) (*Project, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open manifest file %q: %w", path, err)
	}
	defer f.Close()

	var project Project
	decoder := yaml.NewDecoder(f)
	if err := decoder.Decode(&project); err != nil {
		return nil, fmt.Errorf("decode YAML from %q: %w", path, err)
	}

	// Provide sensible defaults if fields are missing.
	if project.APIVersion == "" {
		project.APIVersion = "kazi.bot/v1"
	}
	if project.Kind == "" {
		project.Kind = "Project"
	}
	cfg := &project.Spec.Config
	if cfg.Workspace == "" {
		cfg.Workspace = "."
	}
	if cfg.LintCommand == "" {
		cfg.LintCommand = "go vet ./..."
	}
	if cfg.TestCommand == "" {
		cfg.TestCommand = "go test ./..."
	}

	return &project, nil
}
