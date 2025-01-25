package workflow

import (
	"context"
	"fmt"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/shell"
)

// validator implements Validator interface
type validator struct {
	config config.GlobalConfig
}

// newValidator creates a new validator instance
func newValidator(config config.GlobalConfig) *validator {
	return &validator{
		config: config,
	}
}

// Validate runs configured lint and test commands
func (v *validator) Validate(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		if v.config.LintCommand != "" {
			if err := shell.RunCommand(v.config.Workspace, v.config.LintCommand); err != nil {
				return fmt.Errorf("lint failed: %w", err)
			}
		}

		if v.config.TestCommand != "" {
			if err := shell.RunCommand(v.config.Workspace, v.config.TestCommand); err != nil {
				return fmt.Errorf("tests failed: %w", err)
			}
		}

		return nil
	}
}
