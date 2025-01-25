package shell

import (
	"fmt"
	"os/exec"
)

// RunCommand runs a command in the given directory
func RunCommand(dir, command string) error {
	cmd := exec.Command("sh", "-c", command)
	cmd.Dir = dir
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to run %q: %w", command, err)
	}
	return nil
}

// RunCommandOutput runs a command in the given directory and returns its output
func RunCommandOutput(dir, command string) (string, error) {
	cmd := exec.Command("sh", "-c", command)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to run %q: %w", command, err)
	}
	return string(out), nil
}
