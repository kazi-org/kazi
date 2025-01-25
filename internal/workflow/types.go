package workflow

import (
	"context"
	"io"

	"github.com/go-git/go-git/v5"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	"github.com/kazi-org/kazi/internal/patch"
)

// UserInteractionMode represents the different ways a user can respond to changes
type UserInteractionMode int

const (
	// ModeYes accepts the current change
	ModeYes UserInteractionMode = iota
	// ModeNo rejects the current change
	ModeNo
	// ModeChat allows sending a new/modified prompt to the LLM
	ModeChat
	// ModeAbort aborts the entire operation
	ModeAbort
	// ModeAll accepts all changes in the current prompt
	ModeAll
	// ModeYolo accepts all changes in the list of prompts
	ModeYolo
)

// UserInteraction handles user interaction for accepting changes
type UserInteraction interface {
	// PromptForChanges asks the user to accept or reject changes
	// Returns the user's choice and optionally a new prompt if in chat mode
	PromptForChanges(ctx context.Context, changes *patch.PatchSet) (UserInteractionMode, *config.Prompt, error)
}

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

// LLMClient provides access to language model functionality
type LLMClient interface {
	// GetPatch takes a prompt and returns a JSON string containing the patches to apply.
	GetPatch(ctx context.Context, prompt string) (string, error)
	// StreamPatch takes a prompt and returns a stream of patch chunks.
	StreamPatch(ctx context.Context, prompt string) (io.ReadCloser, error)
}

// ContextStore provides access to code context information
type ContextStore interface {
	// GetCodeContext returns the current code context
	GetCodeContext() *types.CodeContext
	// BuildOrRefresh updates the code context
	BuildOrRefresh(ctx context.Context) error
}

// Options contains the configuration for the workflow processor
type Options struct {
	Workspace string
	Rules     []string
	Context   *types.CodeContext
	Config    config.GlobalConfig
}

// ProcessorConfig holds all dependencies for the workflow processor
type ProcessorConfig struct {
	GitCommitter    GitCommitter
	Validator       Validator
	RequestBuilder  LLMRequestBuilder
	PatchApplier    patch.Applier
	UserInteraction UserInteraction
	LLMClient       LLMClient
	Options         *Options
}

// Workflow represents a sequence of operations to be performed
type Workflow interface {
	// Execute runs the workflow with the given context
	Execute(ctx context.Context) error
}

// WorkflowConfig holds configuration for workflow execution
type WorkflowConfig struct {
	// Rules are project-specific rules to follow
	Rules []string
	// Config is the global configuration
	Config config.GlobalConfig
	// Store provides access to code context
	Store ContextStore
	// LLMClient provides access to language model functionality
	LLMClient LLMClient
}

// WorkflowResult represents the result of a workflow execution
type WorkflowResult struct {
	// Success indicates whether the workflow completed successfully
	Success bool
	// Message contains any output or error message
	Message string
	// CodeContext contains the code context at completion
	CodeContext *types.CodeContext
}
