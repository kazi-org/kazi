package workflow

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/shell"
)

func ProcessPrompt(p config.Prompt, g config.GlobalConfig, rules map[string]string, ctx *contextstore.CodeContext, client ai.LLMClient) error {
	// Build LLM request
	prompt := buildLLMRequest(p, g, rules, ctx)

	// Get patch from LLM
	resp, err := client.GetPatch(context.Background(), prompt)
	if err != nil {
		return fmt.Errorf("get patch from LLM: %w", err)
	}

	// Parse patch set
	var ps patch.PatchSet
	if err := json.Unmarshal([]byte(resp), &ps); err != nil {
		return fmt.Errorf("parse patch JSON: %w", err)
	}

	// Apply patches
	if err := ps.Apply(g.Workspace); err != nil {
		return fmt.Errorf("apply patches: %w", err)
	}

	// Run build/test if configured
	if g.BuildCommand != "" {
		if err := shell.RunCommand(g.Workspace, g.BuildCommand); err != nil {
			return fmt.Errorf("build/test failed: %w", err)
		}
	}
	if g.TestCommand != "" {
		if err := shell.RunCommand(g.Workspace, g.TestCommand); err != nil {
			return fmt.Errorf("build/test failed: %w", err)
		}
	}

	// Show diff and commit
	if err := showDiffAndCommit(p, g.Workspace, &ps); err != nil {
		return fmt.Errorf("commit changes: %w", err)
	}

	return nil
}

func buildLLMRequest(p config.Prompt, g config.GlobalConfig, rules map[string]string, ctx *contextstore.CodeContext) string {
	var b strings.Builder

	// Add project rules
	if len(rules) > 0 {
		b.WriteString("Project Rules:\n")
		for k, v := range rules {
			fmt.Fprintf(&b, "- %s: %s\n", k, v)
		}
	}

	// Add project configuration
	b.WriteString("Project Configuration:\n")
	if g.BuildCommand != "" {
		fmt.Fprintf(&b, "- Build Command: %s\n", g.BuildCommand)
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
	// Show changes
	fmt.Printf("\n--- Processing prompt: %s ---\n\n", p.Name)

	// Get git status
	out, err := shell.RunCommandOutput(workspace, "git status --porcelain")
	if err != nil {
		return fmt.Errorf("get git status: %w", err)
	}
	if out == "" {
		fmt.Println("No changes to commit.")
		return nil
	}
	fmt.Printf("Changes in workspace:\n%s\n\n", out)

	// Show commit message
	fmt.Printf("Proposed commit message:\n%s\n", ps.Commit.Subject)
	if ps.Commit.Body != "" {
		fmt.Printf("\n%s\n", ps.Commit.Body)
	}

	// Stage changes
	if err := shell.RunCommand(workspace, "git add ."); err != nil {
		return fmt.Errorf("stage changes: %w", err)
	}

	// Create commit
	commitMsg := ps.Commit.Subject
	if ps.Commit.Body != "" {
		commitMsg += "\n\n" + ps.Commit.Body
	}
	if err := shell.RunCommand(workspace, fmt.Sprintf("git commit -m %q", commitMsg)); err != nil {
		return fmt.Errorf("create commit: %w", err)
	}

	return nil
}
