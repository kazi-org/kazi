package workflow

import (
	"context"

	"github.com/go-git/go-git/v5"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
)

// Processor handles the workflow of processing prompts and applying changes
type Processor interface {
	// Process takes a prompt and processes it through the LLM, applying the resulting changes
	Process(ctx context.Context, prompt config.Prompt) error
}

// GitCommitter handles git operations for committing changes
type GitCommitter interface {
	// Commit stages and commits changes with the given message
	Commit(ctx context.Context, message string) error
	// Status returns the current git status
	Status(ctx context.Context) (git.Status, error)
}

// Validator handles build and test validation
type Validator interface {
	// Validate runs configured lint and test commands
	Validate(ctx context.Context) error
}

// LLMRequestBuilder builds prompts for the LLM
type LLMRequestBuilder interface {
	// Build creates a formatted request string for the LLM
	Build(prompt config.Prompt) string
}

// Options contains the configuration for the workflow processor
type Options struct {
	Workspace string
	Rules     []string
	Context   *contextstore.CodeContext
	Config    config.GlobalConfig
}

// ProcessorConfig holds all dependencies for the workflow processor
type ProcessorConfig struct {
	GitCommitter   GitCommitter
	Validator      Validator
	RequestBuilder LLMRequestBuilder
	PatchApplier   patch.Applier
	Options        *Options
}
