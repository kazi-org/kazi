package workflow

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/shell"
)

// ProcessPrompt processes a prompt using the workflow processor
func ProcessPrompt(p config.Prompt, g config.GlobalConfig, rules []string, ctx *contextstore.CodeContext, client ai.LLMClient) error {
	// Create options
	opts := &Options{
		Workspace: g.Workspace,
		Rules:     rules,
		Context:   ctx,
		Config:    g,
	}

	// Create dependencies
	gitCommitter, err := newGitCommitter(g.Workspace)
	if err != nil {
		return err
	}

	validator := newValidator(g)
	requestBuilder := newRequestBuilder(rules, g, ctx)
	patchApplier := patch.NewApplier(g.Workspace)

	// Create processor config
	cfg := &ProcessorConfig{
		GitCommitter:   gitCommitter,
		Validator:      validator,
		RequestBuilder: requestBuilder,
		PatchApplier:   patchApplier,
		Options:        opts,
	}

	// Create and run processor
	processor, err := NewProcessor(client, cfg)
	if err != nil {
		return err
	}

	return processor.Process(context.Background(), p)
}

func buildLLMRequest(p config.Prompt, g config.GlobalConfig, rules []string, ctx *contextstore.CodeContext) string {
	var b strings.Builder

	// Add project rules
	if len(rules) > 0 {
		b.WriteString("Project Rules:\n")
		for _, rule := range rules {
			fmt.Fprintf(&b, "- %s\n", rule)
		}
	}

	// Add project configuration
	b.WriteString("Project Configuration:\n")
	if g.LintCommand != "" {
		fmt.Fprintf(&b, "- Lint Command: %s\n", g.LintCommand)
	}
	if g.TestCommand != "" {
		fmt.Fprintf(&b, "- Test Command: %s\n", g.TestCommand)
	}

	// Add workspace context
	if ctx != nil && len(ctx.Files) > 0 {
		b.WriteString("\nWorkspace Context:\n")
		for path, fc := range ctx.Files {
			fmt.Fprintf(&b, "File: %s\n", path)
			if len(fc.Imports) > 0 {
				fmt.Fprintf(&b, "Imports: %s\n", strings.Join(fc.Imports, ", "))
			}
			for name, sc := range fc.Symbols {
				fmt.Fprintf(&b, "Symbol: %s (%s)\n", name, sc.Kind)
				if sc.DocString != "" {
					fmt.Fprintf(&b, "Doc: %s\n", sc.DocString)
				}
			}
		}
	}

	// Add user request
	b.WriteString("\nUser Request:\n")
	b.WriteString(p.Instructions)

	return b.String()
}

func showDiffAndCommit(p config.Prompt, workspace string, ps *patch.PatchSet) error {
	// Open repository
	repo, err := git.PlainOpen(workspace)
	if err != nil {
		return fmt.Errorf("open git repo: %w", err)
	}

	// Get worktree
	wt, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("get worktree: %w", err)
	}

	// Get status
	status, err := wt.Status()
	if err != nil {
		return fmt.Errorf("get git status: %w", err)
	}

	fmt.Printf("\n--- Processing prompt: %s ---\n\n", p.Name)

	if status.IsClean() {
		fmt.Println("No changes to commit.")
		return nil
	}

	fmt.Printf("Changes in workspace:\n%s\n\n", status.String())

	// Show commit message
	fmt.Printf("Proposed commit message:\n%s\n", ps.Commit.Subject)
	if ps.Commit.Body != "" {
		fmt.Printf("\n%s\n", ps.Commit.Body)
	}

	// Stage all changes
	if err := wt.AddGlob("."); err != nil {
		return fmt.Errorf("stage changes: %w", err)
	}

	// Create commit
	commitMsg := ps.Commit.Subject
	if ps.Commit.Body != "" {
		commitMsg += "\n\n" + ps.Commit.Body
	}

	commit, err := wt.Commit(commitMsg, &git.CommitOptions{
		Author: &object.Signature{
			Name:  "Kazi AI",
			Email: "kazi@example.com",
			When:  time.Now(),
		},
	})
	if err != nil {
		return fmt.Errorf("create commit: %w", err)
	}

	// Log the commit hash for debugging
	fmt.Printf("\nCreated commit: %s\n", commit.String())

	return nil
}

// validateBuildAndTest runs the lint and test commands if configured
func validateBuildAndTest(g config.GlobalConfig) error {
	if g.LintCommand != "" {
		if err := shell.RunCommand(g.Workspace, g.LintCommand); err != nil {
			return fmt.Errorf("lint failed: %w", err)
		}
	}
	if g.TestCommand != "" {
		if err := shell.RunCommand(g.Workspace, g.TestCommand); err != nil {
			return fmt.Errorf("tests failed: %w", err)
		}
	}
	return nil
}
