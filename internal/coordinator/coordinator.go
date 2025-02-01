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

// PatchGenerator is the interface for LLM-based patch creation
type PatchGenerator interface {
	GeneratePatch(ctx context.Context, prompt string) (*patch.PatchSet, error)
}

// Coordinator orchestrates the entire LLM-driven workflow
type Coordinator interface {
	ProcessPrompt(ctx context.Context, userPrompt string) error
}

// DefaultCoordinator references memory aggregator, runner, LLM, patch applier, validator
type DefaultCoordinator struct {
	Memory    *memory.MemoryAggregator
	Runner    runner.ExecRunner
	LLM       PatchGenerator
	Applier   patch.Applier
	Validator validator.Pipeline
}

// ProcessPrompt handles user prompt -> patch generation -> apply -> validate
func (dc *DefaultCoordinator) ProcessPrompt(ctx context.Context, userPrompt string) error {
	pset, err := dc.LLM.GeneratePatch(ctx, userPrompt)
	if err != nil {
		return fmt.Errorf("LLM gen patch: %w", err)
	}
	if pset == nil {
		return fmt.Errorf("nil patchset returned")
	}

	// If patch subject says NEED_MEMORY: or RUN_CMD:
	if strings.Contains(pset.Subject, "NEED_MEMORY:") {
		memKey := parseMemoryKey(pset.Subject)
		content, err := dc.Memory.GetMemory(ctx, memKey)
		if err == nil && content != "" {
			newPrompt := userPrompt + "\n\n[MEMORY OUTPUT]\n" + content
			pset, err = dc.LLM.GeneratePatch(ctx, newPrompt)
			if err != nil {
				return err
			}
		}
	}

	if strings.Contains(pset.Subject, "RUN_CMD:") {
		cmdLine := parseCmd(pset.Subject)
		req := runner.ParseLine(cmdLine)
		resp := dc.Runner.RunCommand(ctx, req)
		if resp.Error == nil && resp.Stdout != "" {
			newPrompt := userPrompt + "\n\n[COMMAND OUTPUT]\n" + resp.Stdout
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

	fmt.Println("Patch applied & validated successfully!")
	return nil
}

func parseMemoryKey(subj string) string {
	// naive placeholder
	return "code:UserRepo"
}

func parseCmd(subj string) string {
	// naive placeholder
	return "grep -n 'UserRepository'"
}
