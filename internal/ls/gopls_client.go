//go:build !windows
// +build !windows

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
	"sync"
	"time"

	"github.com/kazi-org/kazi/internal/ls/types"
)

// GoplsClient implements the LSPClient interface using the gopls language server
type GoplsClient struct {
	cmd          *exec.Cmd
	stdin        io.WriteCloser
	stdout       io.ReadCloser
	reader       *bufio.Reader
	mu           sync.Mutex
	ctx          context.Context
	cancel       context.CancelFunc
	idCount      int
	responseC    map[int]chan json.RawMessage
	doneWg       sync.WaitGroup
	workspaceDir string
	timeout      time.Duration
}

// NewGoplsClient creates a new gopls client instance
func NewGoplsClient(ctx context.Context, workspace string, command string, timeout time.Duration) (*GoplsClient, error) {
	if timeout == 0 {
		timeout = 5 * time.Second
	}
	if command == "" {
		command = "gopls"
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
		return nil, fmt.Errorf("initialization failed: %w", err)
	}

	return g, nil
}

// signalGracefulShutdown sends an appropriate signal for graceful shutdown
func signalGracefulShutdown(process *os.Process) error {
	return process.Signal(os.Interrupt)
}

// Close implements the Closer interface
func (g *GoplsClient) Close() error {
	var result interface{}
	if err := g.sendRequest("shutdown", nil, &result); err != nil {
		log.Printf("Warning: LSP shutdown request failed: %v", err)
	}

	if err := g.sendNotification("exit", nil); err != nil {
		log.Printf("Warning: LSP exit notification failed: %v", err)
	}

	g.cancel()
	g.doneWg.Wait()

	if g.cmd.Process != nil {
		if err := signalGracefulShutdown(g.cmd.Process); err != nil {
			log.Printf("Warning: failed to send shutdown signal: %v", err)
		}

		done := make(chan error, 1)
		go func() {
			done <- g.cmd.Wait()
		}()

		select {
		case <-time.After(2 * time.Second):
			log.Printf("Warning: LSP server did not shut down gracefully, forcing termination")
			g.cmd.Process.Kill()
		case err := <-done:
			if err != nil {
				log.Printf("Warning: LSP server exited with error: %v", err)
			}
		}
	}

	return nil
}

// initialize performs the LSP initialization sequence
func (g *GoplsClient) initialize() error {
	params := map[string]interface{}{
		"processId": os.Getpid(),
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
		return fmt.Errorf("initialize request failed: %w", err)
	}

	if err := g.sendNotification("initialized", map[string]interface{}{}); err != nil {
		return fmt.Errorf("initialized notification failed: %w", err)
	}

	return nil
}

// sendRequest sends a JSON-RPC request and waits for the response
func (g *GoplsClient) sendRequest(method string, params interface{}, result interface{}) error {
	g.mu.Lock()
	id := g.idCount
	g.idCount++
	responseC := make(chan json.RawMessage, 1)
	g.responseC[id] = responseC
	g.mu.Unlock()

	req := types.RequestMessage{
		JSONRPC: "2.0",
		ID:      id,
		Method:  method,
		Params:  params,
	}

	if err := json.NewEncoder(g.stdin).Encode(req); err != nil {
		g.mu.Lock()
		delete(g.responseC, id)
		g.mu.Unlock()
		return fmt.Errorf("encode request: %w", err)
	}

	select {
	case response := <-responseC:
		g.mu.Lock()
		delete(g.responseC, id)
		g.mu.Unlock()

		if result != nil {
			if err := json.Unmarshal(response, result); err != nil {
				return fmt.Errorf("decode response: %w", err)
			}
		}
		return nil
	case <-time.After(g.timeout):
		g.mu.Lock()
		delete(g.responseC, id)
		g.mu.Unlock()
		return fmt.Errorf("request timeout after %v", g.timeout)
	case <-g.ctx.Done():
		g.mu.Lock()
		delete(g.responseC, id)
		g.mu.Unlock()
		return g.ctx.Err()
	}
}

// sendNotification sends a JSON-RPC notification (no response expected)
func (g *GoplsClient) sendNotification(method string, params interface{}) error {
	req := types.RequestMessage{
		JSONRPC: "2.0",
		Method:  method,
		Params:  params,
	}
	return json.NewEncoder(g.stdin).Encode(req)
}

// listen handles incoming messages from the language server
func (g *GoplsClient) listen() {
	defer g.doneWg.Done()
	for {
		if err := g.readMessage(); err != nil {
			if err != io.EOF && g.ctx.Err() == nil {
				log.Printf("Error reading message: %v", err)
			}
			return
		}
	}
}

// readMessage reads and processes a single message from the language server
func (g *GoplsClient) readMessage() error {
	var header struct {
		ContentLength int `json:"Content-Length"`
	}

	for {
		line, err := g.reader.ReadString('\n')
		if err != nil {
			return err
		}
		line = line[:len(line)-1]
		if line == "" {
			break
		}
		if n, err := fmt.Sscanf(line, "Content-Length: %d", &header.ContentLength); err != nil || n != 1 {
			continue
		}
	}

	if header.ContentLength == 0 {
		return fmt.Errorf("invalid Content-Length: 0")
	}

	body := make([]byte, header.ContentLength)
	if _, err := io.ReadFull(g.reader, body); err != nil {
		return err
	}

	var resp types.ResponseMessage
	if err := json.Unmarshal(body, &resp); err != nil {
		var req types.RequestMessage
		if err := json.Unmarshal(body, &req); err != nil {
			return fmt.Errorf("decode message: %w", err)
		}
		return g.handleNotification(body)
	}

	return g.handleResponse(body)
}

// handleResponse processes a response message from the language server
func (g *GoplsClient) handleResponse(body []byte) error {
	var resp types.ResponseMessage
	if err := json.Unmarshal(body, &resp); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	g.mu.Lock()
	responseC, ok := g.responseC[resp.ID]
	g.mu.Unlock()

	if !ok {
		return nil // Response for a cancelled request
	}

	if resp.Error != nil {
		responseC <- nil
		return fmt.Errorf("server error: %v", resp.Error.Message)
	}

	responseC <- resp.Result
	return nil
}

// handleNotification processes a notification message from the language server
func (g *GoplsClient) handleNotification(body []byte) error {
	// TODO: Implement notification handling if needed
	return nil
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
