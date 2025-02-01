package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Request is a single command + arguments
type Request struct {
	Command string
	Args    []string
}

// Response holds stdout, stderr, or error
type Response struct {
	Stdout string
	Stderr string
	Error  error
}

// ExecRunner is a single-responsibility interface for running local commands in a restricted environment
type ExecRunner interface {
	RunCommand(ctx context.Context, req Request) Response
}

// AllowedRunner references a map of allowed commands
type AllowedRunner struct {
	Allowed map[string]bool
}

func (ar *AllowedRunner) RunCommand(ctx context.Context, req Request) Response {
	var r Response
	if !ar.Allowed[req.Command] {
		r.Error = errors.New("command not in allowlist")
		return r
	}
	cmd := exec.CommandContext(ctx, req.Command, req.Args...)
	var out, er bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &er
	err := cmd.Run()
	r.Stdout = out.String()
	r.Stderr = er.String()
	r.Error = err
	return r
}

// ParseLine splits a user command line string into a Request
func ParseLine(line string) Request {
	parts := strings.Fields(line)
	if len(parts) == 0 {
		return Request{}
	}
	return Request{Command: parts[0], Args: parts[1:]}
}
