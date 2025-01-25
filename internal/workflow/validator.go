package workflow

import (
	"context"
	"fmt"
	"go/parser"
	"go/token"
	"strings"
	"sync"
	"time"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/kazi-org/kazi/internal/ls/types"
	"github.com/kazi-org/kazi/internal/shell"
	"golang.org/x/sync/errgroup"
)

// ValidationResult represents the result of a validation check
type ValidationResult struct {
	Name        string
	Success     bool
	Error       error
	Details     string
	TimeElapsed time.Duration
}

// ValidationStrategy defines an interface for different validation methods
type ValidationStrategy interface {
	// Validate performs the validation and returns a result
	Validate(ctx context.Context, workspace string) ValidationResult
}

// ShellCommandValidator implements validation using shell commands
type ShellCommandValidator struct {
	name    string
	command string
	timeout time.Duration
}

func (s *ShellCommandValidator) Validate(ctx context.Context, workspace string) ValidationResult {
	start := time.Now()
	result := ValidationResult{Name: s.name}

	// Create a context with timeout
	ctx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	err := shell.RunCommand(workspace, s.command)
	result.TimeElapsed = time.Since(start)

	if err != nil {
		result.Success = false
		result.Error = fmt.Errorf("%s failed: %w", s.name, err)
		return result
	}

	result.Success = true
	return result
}

// SyntaxValidator implements Go syntax validation
type SyntaxValidator struct{}

func (s *SyntaxValidator) Validate(ctx context.Context, workspace string) ValidationResult {
	start := time.Now()
	result := ValidationResult{Name: "syntax"}

	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, workspace, nil, parser.AllErrors)
	result.TimeElapsed = time.Since(start)

	if err != nil {
		result.Success = false
		result.Error = fmt.Errorf("syntax validation failed: %w", err)
		return result
	}

	result.Success = true
	result.Details = fmt.Sprintf("Validated %d packages", len(pkgs))
	return result
}

// LSPValidator implements validation using Language Server diagnostics
type LSPValidator struct {
	client interface {
		CheckCode(code string) (bool, error)
		GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error)
		GetFileContent(filePath string) (string, error)
	}
	timeout time.Duration
}

func (l *LSPValidator) Validate(ctx context.Context, workspace string) ValidationResult {
	start := time.Now()
	result := ValidationResult{Name: "lsp"}

	// Create a context with timeout
	ctx, cancel := context.WithTimeout(ctx, l.timeout)
	defer cancel()

	// Get workspace symbols to validate all files
	symbols, err := l.client.GetWorkspaceSymbols("")
	if err != nil {
		result.Success = false
		result.Error = fmt.Errorf("failed to get workspace symbols: %w", err)
		return result
	}

	// Track validation results
	var (
		errorCount   int
		warningCount int
		errors       []string
		checked      = make(map[string]bool)
	)

	// Check each unique file
	for _, sym := range symbols {
		if checked[sym.Location.URI] {
			continue
		}
		checked[sym.Location.URI] = true

		// Get file content
		content, err := l.client.GetFileContent(sym.Location.URI)
		if err != nil {
			errorCount++
			errors = append(errors, fmt.Sprintf("Failed to read %s: %v", sym.Location.URI, err))
			continue
		}

		// Check file content
		ok, err := l.client.CheckCode(content)
		if err != nil {
			errorCount++
			errors = append(errors, fmt.Sprintf("%s: %v", sym.Location.URI, err))
			continue
		}
		if !ok {
			warningCount++
		}
	}

	result.TimeElapsed = time.Since(start)

	if errorCount > 0 {
		result.Success = false
		result.Error = fmt.Errorf("found %d errors", errorCount)
		result.Details = formatDiagnostics(errors, warningCount)
	} else {
		result.Success = true
		if warningCount > 0 {
			result.Details = fmt.Sprintf("Found %d warnings", warningCount)
		} else {
			result.Details = "No issues found"
		}
	}

	return result
}

func formatDiagnostics(errors []string, warningCount int) string {
	var sb strings.Builder

	// Format errors (show at most 5)
	sb.WriteString("Errors:\n")
	for i, err := range errors {
		if i >= 5 && len(errors) > 6 {
			sb.WriteString(fmt.Sprintf("  ... and %d more errors\n", len(errors)-5))
			break
		}
		sb.WriteString(fmt.Sprintf("  - %s\n", err))
	}

	// Add warning count if any
	if warningCount > 0 {
		sb.WriteString(fmt.Sprintf("\nWarnings: %d", warningCount))
	}

	return sb.String()
}

// validator implements Validator interface with support for multiple validation strategies
type validator struct {
	config     config.GlobalConfig
	strategies []ValidationStrategy
}

// newValidator creates a new validator instance with configured validation strategies
func newValidator(config config.GlobalConfig) *validator {
	v := &validator{
		config:     config,
		strategies: make([]ValidationStrategy, 0),
	}

	// Add syntax validator by default
	v.strategies = append(v.strategies, &SyntaxValidator{})

	// Add LSP validator if language server is configured
	if config.LanguageServer.Command != "" {
		client, err := gols.NewGoClient(context.Background(), config.LanguageServer.Command)
		if err != nil {
			// Log error but continue with other validators
			fmt.Printf("Warning: Failed to initialize LSP client: %v\n", err)
		} else {
			v.strategies = append(v.strategies, &LSPValidator{
				client:  client,
				timeout: 30 * time.Second, // Default timeout for LSP validation
			})
		}
	}

	// Add configured lint command if present
	if config.LintCommand != "" {
		v.strategies = append(v.strategies, &ShellCommandValidator{
			name:    "lint",
			command: config.LintCommand,
			timeout: 30 * time.Second,
		})
	}

	// Add configured test command if present
	if config.TestCommand != "" {
		v.strategies = append(v.strategies, &ShellCommandValidator{
			name:    "test",
			command: config.TestCommand,
			timeout: 60 * time.Second,
		})
	}

	return v
}

// Validate runs all configured validation strategies in parallel
func (v *validator) Validate(ctx context.Context) error {
	g, ctx := errgroup.WithContext(ctx)
	results := make([]ValidationResult, len(v.strategies))
	var mu sync.Mutex

	// Run validations in parallel
	for i, strategy := range v.strategies {
		i, strategy := i, strategy // https://golang.org/doc/faq#closures_and_goroutines
		g.Go(func() error {
			result := strategy.Validate(ctx, v.config.Workspace)
			mu.Lock()
			results[i] = result
			mu.Unlock()

			if !result.Success {
				return result.Error
			}
			return nil
		})
	}

	if err := g.Wait(); err != nil {
		// Format detailed error message with all validation results
		var errMsg string
		for _, r := range results {
			status := "✓"
			if !r.Success {
				status = "✗"
			}
			errMsg += fmt.Sprintf("\n[%s] %s (%.2fs)", status, r.Name, r.TimeElapsed.Seconds())
			if r.Error != nil {
				errMsg += fmt.Sprintf("\n  Error: %v", r.Error)
			}
			if r.Details != "" {
				errMsg += fmt.Sprintf("\n  Details: %s", r.Details)
			}
		}
		return fmt.Errorf("validation failed:%s", errMsg)
	}

	return nil
}
