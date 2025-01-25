package lsp

import (
	"fmt"
	"path/filepath"

	"github.com/kazi-org/kazi/internal/ls/types"
)

// GetWorkspaceSymbols implements SymbolQuerier interface
func (g *GoplsClient) GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error) {
	type wsParams struct {
		Query string `json:"query"`
	}
	var result []types.WorkspaceSymbol
	err := g.sendRequest("workspace/symbol", wsParams{Query: query}, &result)
	if err != nil {
		return nil, fmt.Errorf("workspace symbol request failed: %w", err)
	}
	return result, nil
}

// GetSymbolDocumentation implements SymbolQuerier interface
func (g *GoplsClient) GetSymbolDocumentation(uri string, symbolName string) (string, error) {
	type hoverParams struct {
		TextDocument struct {
			URI string `json:"uri"`
		} `json:"textDocument"`
		Position types.Position `json:"position"`
	}

	var result struct {
		Contents struct {
			Value string `json:"value"`
		} `json:"contents"`
	}

	params := hoverParams{}
	params.TextDocument.URI = uri

	err := g.sendRequest("textDocument/hover", params, &result)
	if err != nil {
		return "", fmt.Errorf("hover request failed: %w", err)
	}

	return result.Contents.Value, nil
}

// GetReferences implements SymbolQuerier interface
func (g *GoplsClient) GetReferences(symbol string) ([]string, error) {
	type referenceParams struct {
		TextDocument struct {
			URI string `json:"uri"`
		} `json:"textDocument"`
		Position types.Position `json:"position"`
		Context  struct {
			IncludeDeclaration bool `json:"includeDeclaration"`
		} `json:"context"`
	}

	var locations []types.Location
	params := referenceParams{}
	params.Context.IncludeDeclaration = true

	err := g.sendRequest("textDocument/references", params, &locations)
	if err != nil {
		return nil, fmt.Errorf("references request failed: %w", err)
	}

	refs := make([]string, len(locations))
	for i, loc := range locations {
		refs[i] = loc.URI
	}

	return refs, nil
}

// GetSymbolDefinition implements SymbolQuerier interface
func (g *GoplsClient) GetSymbolDefinition(filePath, symbolName string) (*types.SymbolDefinition, error) {
	type definitionParams struct {
		TextDocument struct {
			URI string `json:"uri"`
		} `json:"textDocument"`
		Position types.Position `json:"position"`
	}

	var locations []types.Location
	params := definitionParams{}
	params.TextDocument.URI = "file://" + filepath.Join(g.workspaceDir, filePath)

	err := g.sendRequest("textDocument/definition", params, &locations)
	if err != nil {
		return nil, fmt.Errorf("definition request failed: %w", err)
	}

	if len(locations) == 0 {
		return nil, fmt.Errorf("no definition found for symbol %s", symbolName)
	}

	return &types.SymbolDefinition{
		StartLine: locations[0].Range.Start.Line,
		EndLine:   locations[0].Range.End.Line,
		URI:       locations[0].URI,
	}, nil
}

// GetSymbolLocation implements SymbolQuerier interface
func (g *GoplsClient) GetSymbolLocation(filePath, symbolName string) (types.Location, error) {
	def, err := g.GetSymbolDefinition(filePath, symbolName)
	if err != nil {
		return types.Location{}, err
	}

	return types.Location{
		URI: def.URI,
		Range: types.Range{
			Start: types.Position{Line: def.StartLine},
			End:   types.Position{Line: def.EndLine},
		},
	}, nil
}

// GetFileContent implements FileReader interface
func (g *GoplsClient) GetFileContent(filePath string) (string, error) {
	fullPath := filepath.Join(g.workspaceDir, filePath)
	var content string
	err := g.sendRequest("textDocument/documentContent", map[string]string{
		"uri": "file://" + fullPath,
	}, &content)
	if err != nil {
		return "", fmt.Errorf("get file content failed: %w", err)
	}
	return content, nil
}

// CheckCode implements CodeChecker interface
func (g *GoplsClient) CheckCode(code string) (bool, string) {
	// TODO: Implement proper code diagnostics
	return true, ""
}
