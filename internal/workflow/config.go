// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"github.com/kazi-org/kazi/internal/config"
)

// GlobalConfig holds global configuration settings.
type GlobalConfig struct {
	Rules []string // Global rules to apply
}

// Config holds configuration for the workflow.
type Config struct {
	Global GlobalConfig // Global configuration settings
}

// NewConfigFromGlobal creates a new Config from a GlobalConfig.
func NewConfigFromGlobal(g config.GlobalConfig, rules []string) *Config {
	return &Config{
		Global: GlobalConfig{
			Rules: rules,
		},
	}
}
