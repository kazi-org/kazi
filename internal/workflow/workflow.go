package workflow

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"

	"github.com/go-git/go-git/v5"
	"github.com/kazi-org/kazi/internal/ai"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore"
	"github.com/kazi-org/kazi/internal/patch"
)

func ProcessPrompt(
	p config.Prompt,
	g config.GlobalConfig,
	rules map[string]string,
	ctxStore *contextstore.CodeContext,
	llm ai.LLMClient,
) error {
	fmt.Printf("\n--- Processing prompt: %s ---\n", p.Name)

	req := buildLLMRequest(p, g, rules, ctxStore)

	resp, err := llm.GetPatch(context.Background(), req)
	if err != nil {
		return fmt.Errorf("LLM call failed: %w", err)
	}

	var ps patch.PatchSet
	if parseErr := json.Unmarshal([]byte(resp), &ps); parseErr != nil {
		return fmt.Errorf("failed to parse patch JSON: %w", parseErr)
	}

	if err := ps.Apply(g.Workspace); err != nil {
		return fmt.Errorf("patch application error: %v", err)
	}

	if err := validateBuildAndTest(g); err != nil {
		return fmt.Errorf("build/test failed: %v", err)
	}

	if err := showDiffAndCommit(p, g.Workspace); err != nil {
		return fmt.Errorf("commit process failed: %v", err)
	}

	return nil
}

func buildLLMRequest(
	p config.Prompt,
	g config.GlobalConfig,
	rules map[string]string,
	ctxStore *contextstore.CodeContext,
) string {
	rulesStr := ""
	for k, v := range rules {
		rulesStr += fmt.Sprintf("%s: %s\n", k, v)
	}
	return fmt.Sprintf(`
You are a coding assistant. Follow these project rules:
%s

User prompt: %s

Provide a JSON patch in the form:
{
  "patches": [
    {"file":"...","type":"replace|create|delete","fromLine":...,"toLine":...,"content":"..."}
  ]
}
`, rulesStr, p.Instructions)
}

func validateBuildAndTest(g config.GlobalConfig) error {
	if g.BuildCommand != "" {
		if err := runCommand(g.Workspace, g.BuildCommand); err != nil {
			return fmt.Errorf("build command failed: %v", err)
		}
	}
	if g.TestCommand != "" {
		if err := runCommand(g.Workspace, g.TestCommand); err != nil {
			return fmt.Errorf("test command failed: %v", err)
		}
	}
	return nil
}

func runCommand(dir, command string) error {
	fmt.Printf("Running command: %s in %s\n", command, dir)
	cmd := exec.Command("sh", "-c", command)
	cmd.Dir = dir
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func showDiffAndCommit(p config.Prompt, workspace string) error {
	repo, err := git.PlainOpen(workspace)
	if err != nil {
		return fmt.Errorf("open git repo: %v", err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("worktree error: %v", err)
	}
	status, err := wt.Status()
	if err != nil {
		return fmt.Errorf("git status: %v", err)
	}
	if !status.IsClean() {
		fmt.Println("Changes in workspace:")
		fmt.Println(status.String())
		fmt.Println("[y]es to commit, [n]o to skip?")
		var ans string
		fmt.Scanln(&ans)
		if ans == "y" || ans == "yes" {
			if _, err := wt.Add("."); err != nil {
				return fmt.Errorf("wt add: %v", err)
			}
			commitMsg := fmt.Sprintf("Implement prompt: %s", p.Name)
			hash, cerr := wt.Commit(commitMsg, &git.CommitOptions{})
			if cerr != nil {
				return fmt.Errorf("commit error: %v", cerr)
			}
			obj, _ := repo.CommitObject(hash)
			fmt.Printf("Committed: %s\n", obj.String())
		} else {
			fmt.Println("Skipping commit.")
		}
	} else {
		fmt.Println("No changes to commit.")
	}
	return nil
}
