package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Request for a system command
type Request struct {
	Command string
	Args    []string
}

// Response after running
type Response struct {
	Stdout string
	Stderr string
	Error  error
}

// ExecRunner is the single interface
type ExecRunner interface {
	RunCommand(ctx context.Context, req Request) Response
}

// AllowedRunner references a allowlist
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

func ParseLine(line string) Request {
	parts := strings.Fields(line)
	if len(parts) == 0 {
		return Request{}
	}
	return Request{Command: parts[0], Args: parts[1:]}
}
