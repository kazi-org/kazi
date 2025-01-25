package workflow

import (
	"context"
	"fmt"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// gitCommitter implements GitCommitter interface
type gitCommitter struct {
	workspace string
	repo      *git.Repository
	wt        *git.Worktree
}

// newGitCommitter creates a new gitCommitter instance
func newGitCommitter(workspace string) (*gitCommitter, error) {
	repo, err := git.PlainOpen(workspace)
	if err != nil {
		return nil, fmt.Errorf("open git repo: %w", err)
	}

	wt, err := repo.Worktree()
	if err != nil {
		return nil, fmt.Errorf("get worktree: %w", err)
	}

	return &gitCommitter{
		workspace: workspace,
		repo:      repo,
		wt:        wt,
	}, nil
}

// Status returns the current git status
func (g *gitCommitter) Status(ctx context.Context) (git.Status, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
		status, err := g.wt.Status()
		if err != nil {
			return nil, fmt.Errorf("get git status: %w", err)
		}
		return status, nil
	}
}

// Commit stages and commits changes with the given message
func (g *gitCommitter) Commit(ctx context.Context, message string) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		// Stage all changes
		if err := g.wt.AddGlob("."); err != nil {
			return fmt.Errorf("stage changes: %w", err)
		}

		// Create commit
		_, err := g.wt.Commit(message, &git.CommitOptions{
			Author: &object.Signature{
				Name:  "Kazi AI",
				Email: "kazi@example.com",
				When:  time.Now(),
			},
		})
		if err != nil {
			return fmt.Errorf("create commit: %w", err)
		}

		return nil
	}
}
