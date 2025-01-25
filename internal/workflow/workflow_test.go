// Package workflow provides functionality for building and executing AI requests.
package workflow

import (
	"context"
	"testing"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	"github.com/stretchr/testify/assert"
)

func TestProcess(t *testing.T) {
	tests := []struct {
		name    string
		codeCtx *types.CodeContext
		rules   []string
		global  config.GlobalConfig
		prompt  string
		want    string
	}{
		{
			name: "basic workflow",
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
			want: `Global rules:
- rule1
- rule2

Specific rules:
- rule1
- rule2

Code context:
main.go:
- main: func main()
  Kind: function
  Doc: main function

Instructions:
test instructions`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Process(context.Background(), tc.codeCtx, tc.prompt, tc.rules, tc.global)
			assert.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}
}
