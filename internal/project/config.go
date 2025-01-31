// config.go
//
// Holds operational or build-time configuration (workspace, lint/test commands, etc.).
// This does NOT store domain constraints or architecture details.

package project

// Config captures operational details such as workspace paths, commands, or environment flags.
type Config struct {
	// Workspace is the path to the codebase root directory.
	Workspace string

	// LintCommand is the shell command used for linting. e.g., "go vet ./..."
	LintCommand string

	// TestCommand is the shell command used for testing. e.g., "go test ./..."
	TestCommand string

	// Additional fields (e.g., SecurityTool, DeploymentConfig) could go here.
}

// ConfigManager is a specialized interface for loading/updating config data.
type ConfigManager interface {
	// LoadConfig reads configuration (YAML, JSON, env vars, etc.) and returns a Config.
	LoadConfig(pathOrData string) (*Config, error)

	// UpdateConfig modifies existing config (e.g. changing lint/test commands).
	UpdateConfig(c *Config) error
}
