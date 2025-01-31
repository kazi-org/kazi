// internal/vision/yaml_loader.go
//
// Package vision provides a YAMLLoader to read the Vision Contract from a YAML file.
package vision

import (
	"os"

	"gopkg.in/yaml.v3"
)

// YAMLLoader implements the Loader interface for Vision Contracts, reading them from YAML files.
type YAMLLoader struct{}

// LoadContract reads a Vision Contract from the specified YAML file.
func (l *YAMLLoader) LoadContract(pathOrData string) (*Contract, error) {
	data, err := os.ReadFile(pathOrData)
	if err != nil {
		return nil, err
	}

	var contract Contract
	if err := yaml.Unmarshal(data, &contract); err != nil {
		return nil, err
	}

	return &contract, nil
}
