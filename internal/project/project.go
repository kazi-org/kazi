package project

import (
	"context"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Project merges domain constraints, architecture, config, ephemeral logs, chunk references, progress
type Project struct {
	Name        string
	Description string
	Constraints map[string]string

	Modules []ModuleSpec

	Workspace   string
	LintCommand string
	TestCommand string

	Logs            []string
	ChunkReferences map[string]string

	Progress ProgressState
}

type ModuleSpec struct {
	Name       string
	Interfaces []InterfaceSpec
}

type InterfaceSpec struct {
	Name    string
	Methods []MethodSig
}

type MethodSig struct {
	Name       string
	Parameters []string
	Returns    []string
}

// ProgressState tracks a map of stepName -> status
type ProgressState struct {
	Steps map[string]ProgressStatus
}

type ProgressStatus string

const (
	NotStarted ProgressStatus = "not-started"
	InProgress ProgressStatus = "in-progress"
	Completed  ProgressStatus = "completed"
)

func (ps *ProgressState) MarkStep(stepName string, status ProgressStatus) {
	if ps.Steps == nil {
		ps.Steps = make(map[string]ProgressStatus)
	}
	ps.Steps[stepName] = status
}

// ProjectManager for loading/saving
type ProjectManager interface {
	LoadProject(ctx context.Context, path string) (*Project, error)
	SaveProject(ctx context.Context, path string, p *Project) error
	AddModule(ctx context.Context, p *Project, mod ModuleSpec) error
	AddLog(ctx context.Context, p *Project, msg string) error
	MarkProgress(ctx context.Context, p *Project, stepName string, status ProgressStatus) error
}

// DefaultProjectManager for a simple YAML-based approach
type DefaultProjectManager struct{}

func (dpm *DefaultProjectManager) LoadProject(ctx context.Context, path string) (*Project, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read file: %w", err)
	}
	var proj Project
	if err := yaml.Unmarshal(data, &proj); err != nil {
		return nil, fmt.Errorf("unmarshal project: %w", err)
	}
	return &proj, nil
}

func (dpm *DefaultProjectManager) SaveProject(ctx context.Context, path string, p *Project) error {
	out, err := yaml.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal project: %w", err)
	}
	if err := os.WriteFile(path, out, 0644); err != nil {
		return fmt.Errorf("write file: %w", err)
	}
	return nil
}

func (dpm *DefaultProjectManager) AddModule(ctx context.Context, p *Project, mod ModuleSpec) error {
	p.Modules = append(p.Modules, mod)
	return nil
}

func (dpm *DefaultProjectManager) AddLog(ctx context.Context, p *Project, msg string) error {
	p.Logs = append(p.Logs, msg)
	return nil
}

func (dpm *DefaultProjectManager) MarkProgress(ctx context.Context, p *Project, stepName string, status ProgressStatus) error {
	p.Progress.MarkStep(stepName, status)
	return nil
}
