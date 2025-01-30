// Package config manages a single Kubernetes-style manifest that merges
// the Vision Contract and KaziConfig into one structure.
//
// Example YAML (.kazi.yaml):
//   apiVersion: kazi.io/v1
//   kind: KaziProject
//   metadata:
//     name: my-project
//   spec:
//     contract:
//       name: "Payment Gateway"
//       description: "Implement PayPal integration"
//       constraints:
//         compliance: "PCI-DSS"
//     config:
//       workspace: "/path/to/project"
//       lintCommand: "go vet ./..."
//       testCommand: "go test ./..."
//
// Then your coordinator can load it all at once.

package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// KaziProject is a top-level struct for the K8s-style manifest.
type KaziProject struct {
	APIVersion string   `yaml:"apiVersion"`
	Kind       string   `yaml:"kind"`
	Metadata   Metadata `yaml:"metadata"`
	Spec       Spec     `yaml:"spec"`
}

// Metadata holds standard "k8s-like" metadata.
type Metadata struct {
	Name   string            `yaml:"name"`
	Labels map[string]string `yaml:"labels,omitempty"`
}

// Spec merges the Vision Contract and operational config.
type Spec struct {
	Contract Contract   `yaml:"contract"`
	Config   KaziConfig `yaml:"config"`
}

// Contract represents the product vision portion.
type Contract struct {
	Name        string            `yaml:"name"`
	Description string            `yaml:"description"`
	Constraints map[string]string `yaml:"constraints,omitempty"`
}

// KaziConfig represents operational details (workspace, lint/test commands, etc.).
type KaziConfig struct {
	Workspace   string `yaml:"workspace"`
	LintCommand string `yaml:"lintCommand"`
	TestCommand string `yaml:"testCommand"`
}

// LoadManifest reads a .kazi.yaml file (K8s-style) and decodes it into KaziProject.
func LoadManifest(path string) (*KaziProject, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open manifest file %q: %w", path, err)
	}
	defer f.Close()

	var project KaziProject
	decoder := yaml.NewDecoder(f)
	if err := decoder.Decode(&project); err != nil {
		return nil, fmt.Errorf("decode YAML from %q: %w", path, err)
	}

	// Provide sensible defaults if fields are missing
	if project.APIVersion == "" {
		project.APIVersion = "kazi.io/v1"
	}
	if project.Kind == "" {
		project.Kind = "KaziProject"
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
