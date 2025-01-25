package lsp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LSPClient is the interface your code references
type LSPClient interface {
	GetWorkspaceSymbols(query string) ([]WorkspaceSymbol, error)
	GetSymbolDocumentation(uri string, symbolName string) (string, error)
	GetReferences(symbol string) ([]string, error)
	GetSymbolDefinition(filePath, symbolName string) (*SymbolDefinition, error)
	GetFileContent(filePath string) (string, error)
	GetSymbolLocation(filePath, symbolName string) (Location, error)
	CheckCode(code string) (bool, string)
	Close() error
}

// GoplsClient is a minimal JSON-RPC client for gopls
type GoplsClient struct {
	cmd       *exec.Cmd
	stdin     io.WriteCloser
	stdout    io.ReadCloser
	reader    *bufio.Reader
	mu        sync.Mutex
	ctx       context.Context
	cancel    context.CancelFunc
	idCount   int
	responseC map[int]chan json.RawMessage
	doneWg    sync.WaitGroup

	workspaceDir string
	timeout      time.Duration // timeout for LSP requests
}

// NewNoopClient returns a no-op client if we fail to start gopls
func NewNoopClient() LSPClient {
	return &noopClient{}
}

// Noop client does nothing
type noopClient struct{}

func (n *noopClient) GetWorkspaceSymbols(query string) ([]WorkspaceSymbol, error) {
	return nil, nil
}
func (n *noopClient) GetSymbolDocumentation(uri string, symbolName string) (string, error) {
	return "", nil
}
func (n *noopClient) GetReferences(symbol string) ([]string, error) {
	return nil, nil
}
func (n *noopClient) GetSymbolDefinition(filePath, symbolName string) (*SymbolDefinition, error) {
	return nil, nil
}
func (n *noopClient) GetFileContent(filePath string) (string, error) {
	return "", nil
}
func (n *noopClient) GetSymbolLocation(filePath, symbolName string) (Location, error) {
	return Location{}, nil
}
func (n *noopClient) CheckCode(code string) (bool, string) {
	return true, ""
}
func (n *noopClient) Close() error {
	return nil
}

// NewGoplsClient spawns a gopls process, does "initialize" request
func NewGoplsClient(ctx context.Context, workspace string, command string, timeout time.Duration) (*GoplsClient, error) {
	if timeout == 0 {
		timeout = 5 * time.Second // default timeout
	}
	if command == "" {
		command = "gopls" // default command
	}

	ctx2, cancel := context.WithCancel(ctx)
	cmd := exec.CommandContext(ctx2, command)
	cmd.Dir = workspace

	stdin, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return nil, fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = log.Writer()

	if err := cmd.Start(); err != nil {
		cancel()
		return nil, fmt.Errorf("start %s: %w", command, err)
	}

	g := &GoplsClient{
		cmd:          cmd,
		stdin:        stdin,
		stdout:       stdout,
		reader:       bufio.NewReader(stdout),
		ctx:          ctx2,
		cancel:       cancel,
		responseC:    make(map[int]chan json.RawMessage),
		workspaceDir: workspace,
		timeout:      timeout,
	}

	g.doneWg.Add(1)
	go g.listen()

	if err := g.initialize(); err != nil {
		g.Close()
		return nil, fmt.Errorf("%s init: %w", command, err)
	}

	return g, nil
}

func (g *GoplsClient) Close() error {
	g.cancel()
	g.doneWg.Wait()
	if g.cmd.Process != nil {
		g.cmd.Process.Kill()
	}
	return nil
}

// minimal "CheckCode"
func (g *GoplsClient) CheckCode(code string) (bool, string) {
	// skipping real diag code for brevity
	return true, ""
}

// placeholders
func (g *GoplsClient) GetWorkspaceSymbols(query string) ([]WorkspaceSymbol, error) {
	// do a "workspace/symbol" request
	type wsParams struct {
		Query string `json:"query"`
	}
	var result []WorkspaceSymbol
	err := g.sendRequest("workspace/symbol", wsParams{Query: query}, &result)
	if err != nil {
		return nil, err
	}
	return result, nil
}
func (g *GoplsClient) GetSymbolDocumentation(uri string, symbolName string) (string, error) {
	return "", nil
}
func (g *GoplsClient) GetReferences(symbol string) ([]string, error) {
	return nil, nil
}
func (g *GoplsClient) GetSymbolDefinition(filePath, symbolName string) (*SymbolDefinition, error) {
	return nil, nil
}
func (g *GoplsClient) GetSymbolLocation(filePath, symbolName string) (Location, error) {
	return Location{}, nil
}
func (g *GoplsClient) GetFileContent(filePath string) (string, error) {
	// read from disk for now
	full := filepath.Join(g.workspaceDir, filePath)
	data, err := os.ReadFile(full)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// minimal JSON-RPC initialization
func (g *GoplsClient) initialize() error {
	params := map[string]interface{}{
		"processId": 12345,
		"rootUri":   "file://" + g.workspaceDir,
		"capabilities": map[string]interface{}{
			"textDocument": map[string]interface{}{
				"synchronization": map[string]interface{}{
					"didSave": true,
				},
			},
		},
	}
	var initRes interface{}
	if err := g.sendRequest("initialize", params, &initRes); err != nil {
		return err
	}
	if err := g.sendNotification("initialized", map[string]interface{}{}); err != nil {
		return err
	}
	return nil
}

// we define a minimal JSON-RPC request/response
func (g *GoplsClient) sendRequest(method string, params interface{}, result interface{}) error {
	g.mu.Lock()
	g.idCount++
	id := g.idCount
	ch := make(chan json.RawMessage, 1)
	g.responseC[id] = ch
	g.mu.Unlock()

	req := RequestMessage{
		JSONRPC: "2.0",
		ID:      id,
		Method:  method,
		Params:  params,
	}
	data, err := json.Marshal(req)
	if err != nil {
		return err
	}
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(data))
	_, err = g.stdin.Write([]byte(header))
	if err != nil {
		return err
	}
	_, err = g.stdin.Write(data)
	if err != nil {
		return err
	}

	select {
	case raw := <-ch:
		// parse base
		var base ResponseMessage
		if e := json.Unmarshal(raw, &base); e != nil {
			return e
		}
		if base.Error != nil {
			return fmt.Errorf("lsp error: %s", base.Error.Message)
		}
		if result != nil {
			if e := json.Unmarshal(base.Result, result); e != nil {
				return e
			}
		}
		return nil
	case <-time.After(g.timeout):
		return fmt.Errorf("request %s timed out after %v", method, g.timeout)
	case <-g.ctx.Done():
		return fmt.Errorf("context canceled")
	}
}

func (g *GoplsClient) sendNotification(method string, params interface{}) error {
	notif := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
	}
	data, err := json.Marshal(notif)
	if err != nil {
		return err
	}
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(data))
	if _, err := g.stdin.Write([]byte(header)); err != nil {
		return err
	}
	if _, err := g.stdin.Write(data); err != nil {
		return err
	}
	return nil
}

func (g *GoplsClient) listen() {
	defer g.doneWg.Done()
	for {
		select {
		case <-g.ctx.Done():
			return
		default:
			if err := g.readMessage(); err != nil {
				log.Printf("gopls read error: %v", err)
				return
			}
		}
	}
}

func (g *GoplsClient) readMessage() error {
	headers := make(map[string]string)
	for {
		line, err := g.reader.ReadString('\n')
		if err != nil {
			return err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) == 2 {
			headers[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
		}
	}
	lengthStr, ok := headers["Content-Length"]
	if !ok {
		return nil
	}
	length, err := strconv.Atoi(lengthStr)
	if err != nil {
		return err
	}
	body := make([]byte, length)
	_, err = io.ReadFull(g.reader, body)
	if err != nil {
		return err
	}

	var raw map[string]interface{}
	if e := json.Unmarshal(body, &raw); e != nil {
		return e
	}

	if _, hasID := raw["id"]; hasID {
		g.handleResponse(body)
	} else if _, hasMethod := raw["method"]; hasMethod {
		g.handleNotification(body)
	}
	return nil
}

func (g *GoplsClient) handleResponse(body []byte) {
	var base ResponseMessage
	if e := json.Unmarshal(body, &base); e != nil {
		log.Printf("handleResp unmarshal: %v", e)
		return
	}
	id := base.ID
	g.mu.Lock()
	ch, ok := g.responseC[id]
	if ok {
		ch <- body
		close(ch)
		delete(g.responseC, id)
	}
	g.mu.Unlock()
}

func (g *GoplsClient) handleNotification(body []byte) {
	log.Printf("gopls notification: %s", string(body))
}

// minimal types
type RequestMessage struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int         `json:"id,omitempty"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type ResponseMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *ResponseError  `json:"error,omitempty"`
}

type ResponseError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Basic geometry for references/definition
type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}
type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}
type Location struct {
	URI   string `json:"uri"`
	Range Range  `json:"range"`
}
type SymbolDefinition struct {
	StartLine int
	EndLine   int
	URI       string
}

// SymbolKind
type SymbolKind int

const (
	Function  SymbolKind = 12
	Struct    SymbolKind = 23
	Interface SymbolKind = 11
)

// WorkspaceSymbol is minimal for "workspace/symbol"
type WorkspaceSymbol struct {
	Name     string     `json:"name"`
	Kind     SymbolKind `json:"kind"`
	Location struct {
		URI   string `json:"uri"`
		Range struct {
			Start Position `json:"start"`
			End   Position `json:"end"`
		} `json:"range"`
	} `json:"location"`
}
