// commands.go
//
// Provides default checks that run shell commands (like lint, test) for a given project config.
// This is a typical scenario in Kazi, referencing the workspace or commands from config.

package validation

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"time"
)

// ShellCheck is a Check that runs a single shell command, capturing success/failure.
type ShellCheck struct {
	Command string // e.g. "go vet ./..."
	NameVal string // e.g. "LintCheck"
	WorkDir string // optional; might be the project's workspace
	Timeout time.Duration
}

// Name returns the check's short identifier.
func (sc ShellCheck) Name() string {
	if sc.NameVal != "" {
		return sc.NameVal
	}
	return "ShellCheck"
}

// Run executes the shell command. If it fails or times out, we set success=false in the result.
func (sc ShellCheck) Run(ctx context.Context) ValidationResult {
	res := ValidationResult{Name: sc.Name()}

	// If Timeout is set, wrap context
	var cancel context.CancelFunc
	if sc.Timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, sc.Timeout)
		defer cancel()
	}

	cmd := exec.CommandContext(ctx, "sh", "-c", sc.Command)
	if sc.WorkDir != "" {
		cmd.Dir = sc.WorkDir
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		res.Success = false
		res.Errors = append(res.Errors, fmt.Errorf("command failed: %w, output: %s", err, string(out)))
		return res
	}
	res.Success = true
	return res
}

// Example: create checks for lint/test using the above shell approach
func NewLintCheck(lintCommand, workDir string) Check {
	return &ShellCheck{
		Command: lintCommand,
		NameVal: "LintCheck",
		WorkDir: workDir,
		Timeout: 30 * time.Second, // some default
	}
}

func NewTestCheck(testCommand, workDir string) Check {
	return &ShellCheck{
		Command: testCommand,
		NameVal: "TestCheck",
		WorkDir: workDir,
		Timeout: 2 * time.Minute,
	}
}
