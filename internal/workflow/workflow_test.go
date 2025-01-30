// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"context"
	"fmt"
	"io"
	"testing"

	"github.com/go-git/go-git/v5"
	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

type mockLLMClient struct {
	mock.Mock
}

func (m *mockLLMClient) GetPatch(ctx context.Context, prompt string) (string, error) {
	args := m.Called(ctx, prompt)
	return args.String(0), args.Error(1)
}

func (m *mockLLMClient) StreamPatch(ctx context.Context, prompt string) (io.ReadCloser, error) {
	return nil, fmt.Errorf("not implemented")
}

type mockValidator struct {
	mock.Mock
}

func (m *mockValidator) Validate(ctx context.Context) error {
	args := m.Called(ctx)
	return args.Error(0)
}

type mockGitCommitter struct {
	mock.Mock
}

func (m *mockGitCommitter) Commit(ctx context.Context, msg string) error {
	args := m.Called(ctx, msg)
	return args.Error(0)
}

func (m *mockGitCommitter) Status(ctx context.Context) (git.Status, error) {
	args := m.Called(ctx)
	if s, ok := args.Get(0).(git.Status); ok {
		return s, args.Error(1)
	}
	return git.Status{}, args.Error(1)
}

func TestProcess(t *testing.T) {
	tests := []struct {
		name    string
		codeCtx *types.CodeContext
		rules   []string
		global  config.GlobalConfig
		prompt  string
		patch   string
		want    *patch.PatchSet
		wantErr bool
	}{
		{
			name: "valid patch",
			codeCtx: &types.CodeContext{
				Files: map[string]*types.FileContext{
					"main.go": {
						FilePath: "main.go",
						Symbols: map[string]*types.SymbolContext{
							"main": {
								Name:      "main",
								Kind:      string(types.KindFunction),
								DocString: "main function",
								Signature: "func main()",
							},
						},
					},
				},
			},
			rules: []string{"rule1", "rule2"},
			global: config.GlobalConfig{
				Workspace:   ".",
				LintCommand: "go vet ./...",
				TestCommand: "go test ./...",
				LanguageServer: config.LanguageServer{
					Name:    "gopls",
					Command: "gopls serve",
					Timeout: "30s",
				},
			},
			prompt: "test instructions",
			patch:  `{"commit":{"subject":"Test changes"},"patches":[{"file":"main.go","type":"replace","fromLine":3,"toLine":4,"linesBefore":["func main() {","    println(\"Hello, World!\"))","}"],"linesAfter":["func main() {","    fmt.Println(\"Hello, World!\"))","}"],"content":"    fmt.Println(\"Hello, World!\"))"}]}`,
			want: &patch.PatchSet{
				Commit: patch.CommitMessage{
					Subject: "Test changes",
				},
				Patches: []patch.Chunk{
					{
						File:        "main.go",
						Type:        patch.PatchReplace,
						FromLine:    3,
						ToLine:      4,
						LinesBefore: []string{"func main() {", "    println(\"Hello, World!\"))", "}"},
						LinesAfter:  []string{"func main() {", "    fmt.Println(\"Hello, World!\"))", "}"},
						Content:     "    fmt.Println(\"Hello, World!\"))",
					},
				},
			},
			wantErr: false,
		},
		{
			name: "invalid json",
			codeCtx: &types.CodeContext{
				Files: map[string]*types.FileContext{
					"main.go": {
						FilePath: "main.go",
						Symbols: map[string]*types.SymbolContext{
							"main": {
								Name:      "main",
								Kind:      string(types.KindFunction),
								DocString: "main function",
								Signature: "func main()",
							},
						},
					},
				},
			},
			rules: []string{"rule1", "rule2"},
			global: config.GlobalConfig{
				Workspace:   ".",
				LintCommand: "go vet ./...",
				TestCommand: "go test ./...",
				LanguageServer: config.LanguageServer{
					Name:    "gopls",
					Command: "gopls serve",
					Timeout: "30s",
				},
			},
			prompt:  "test instructions",
			patch:   `{"commit":{"subject":"Invalid JSON"},"patches":[{"file":"main.go","type":"replace","fromLine":3,"toLine":4,"linesBefore":["func main() {","    println(\"Hello, World!\"))","}"],"linesAfter":["func main() {","    fmt.Println(\"Hello\"))","}"],"content":"    fmt.Println(\"Hello\"))",,,}]}`,
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create mock LLM client
			mockLLM := new(mockLLMClient)
			mockLLM.On("GetPatch", mock.Anything, mock.Anything).Return(tc.patch, nil)

			// Create workflow with mock client
			w := &workflow{
				codeCtx: tc.codeCtx,
				rules:   tc.rules,
				config:  tc.global,
				ai:      mockLLM,
			}

			// Execute workflow
			got, err := w.Execute(context.Background(), tc.prompt)
			if tc.wantErr {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tc.want, got)
			}

			mockLLM.AssertExpectations(t)
		})
	}
}
