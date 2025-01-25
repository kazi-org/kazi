package lsp

import "github.com/kazi-org/kazi/internal/ls/types"

// NewNoopClient returns a no-op client if we fail to start gopls
func NewNoopClient() LSPClient {
	return &noopClient{}
}

// noopClient is a no-op implementation of LSPClient
type noopClient struct{}

// GetWorkspaceSymbols implements LSPClient interface
func (n *noopClient) GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error) {
	return nil, nil
}

// GetSymbolDocumentation implements LSPClient interface
func (n *noopClient) GetSymbolDocumentation(uri string, symbolName string) (string, error) {
	return "", nil
}

// GetReferences implements LSPClient interface
func (n *noopClient) GetReferences(symbol string) ([]string, error) {
	return nil, nil
}

// GetSymbolDefinition implements LSPClient interface
func (n *noopClient) GetSymbolDefinition(filePath, symbolName string) (*types.SymbolDefinition, error) {
	return nil, nil
}

// GetFileContent implements LSPClient interface
func (n *noopClient) GetFileContent(filePath string) (string, error) {
	return "", nil
}

// GetSymbolLocation implements LSPClient interface
func (n *noopClient) GetSymbolLocation(filePath, symbolName string) (types.Location, error) {
	return types.Location{}, nil
}

// CheckCode implements LSPClient interface
func (n *noopClient) CheckCode(code string) (bool, string) {
	return true, ""
}

// Close implements LSPClient interface
func (n *noopClient) Close() error {
	return nil
}
