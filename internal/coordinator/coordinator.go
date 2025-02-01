package coordinator

import (
	"context"
	"fmt"
	"strings"

	"github.com/yourorg/kazi/internal/memory"
	"github.com/yourorg/kazi/internal/patch"
	"github.com/yourorg/kazi/internal/runner"
	"github.com/yourorg/kazi/internal/validator"
)

// PatchGenerator is an interface for LLM-based patch generation
type PatchGenerator interface {
	GeneratePatch(ctx context.Context, prompt string) (*patch.PatchSet, error)
}

// Coordinator orchestrates the entire flow
type Coordinator interface {
	ProcessPrompt(ctx context.Context, userPrompt string) error
}

// DefaultCoordinator composes memory aggregator, runner, patch logic, validator, plus an LLM generator
type DefaultCoordinator struct {
	Memory    *memory.MemoryAggregator
	Runner    runner.ExecRunner
	LLM       PatchGenerator
	Applier   patch.Applier
	Validator validator.Pipeline
}

func (dc *DefaultCoordinator) ProcessPrompt(ctx context.Context, userPrompt string) error {
	pset, err := dc.LLM.GeneratePatch(ctx, userPrompt)
	if err != nil {
		return fmt.Errorf("llm gen patch: %w", err)
	}
	if pset == nil {
		return fmt.Errorf("patchset is nil")
	}

	// If patch subject says "NEED_MEMORY: code:UserRepo" or "RUN_CMD: grep..."
	if strings.Contains(pset.Subject, "NEED_MEMORY:") {
		key := parseMemKey(pset.Subject)
		content, err := dc.Memory.GetMemory(ctx, key)
		if err == nil && content != "" {
			newPrompt := userPrompt + "\n\n[MEMORY CONTENT]\n" + content
			pset, err = dc.LLM.GeneratePatch(ctx, newPrompt)
			if err != nil {
				return err
			}
		}
	}

	if strings.Contains(pset.Subject, "RUN_CMD:") {
		cmdLine := parseCmdLine(pset.Subject)
		req := runner.ParseLine(cmdLine)
		out := dc.Runner.RunCommand(ctx, req)
		if out.Error == nil && out.Stdout != "" {
			newPrompt := userPrompt + "\n\n[COMMAND OUTPUT]\n" + out.Stdout
			pset, err = dc.LLM.GeneratePatch(ctx, newPrompt)
			if err != nil {
				return err
			}
		}
	}

	err = dc.Applier.Apply(ctx, pset)
	if err != nil {
		return fmt.Errorf("apply patch: %w", err)
	}

	res := dc.Validator.ValidateAll(ctx)
	if !res.Success {
		return fmt.Errorf("validation failed: %v", res.Error())
	}

	fmt.Println("Patch applied & validated!")
	return nil
}

func parseMemKey(subj string) string {
	// naive
	return "code:UserRepo"
}

func parseCmdLine(subj string) string {
	return "grep -n 'UserRepository'"
}
