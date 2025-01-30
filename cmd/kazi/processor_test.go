package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"testing"

	"github.com/go-git/go-git/v5"
	"github.com/kazi-org/kazi/internal/workflow"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

// testLLMClient implements ai.LLMClient for testing
type testLLMClient struct {
	mock.Mock
}

func (m *testLLMClient) GetPatch(ctx context.Context, prompt string) (string, error) {
	args := m.Called(ctx, prompt)
	return args.String(0), args.Error(1)
}

func (m *testLLMClient) StreamPatch(ctx context.Context, prompt string) (io.ReadCloser, error) {
	return nil, fmt.Errorf("not implemented")
}

// testValidator implements workflow.Validator for testing
type testValidator struct {
	mock.Mock
}

func (m *testValidator) Validate(ctx context.Context) error {
	args := m.Called(ctx)
	return args.Error(0)
}

// testGitCommitter implements workflow.GitCommitter for testing
type testGitCommitter struct {
	mock.Mock
}

func (m *testGitCommitter) Commit(ctx context.Context, msg string) error {
	args := m.Called(ctx, msg)
	return args.Error(0)
}

func (m *testGitCommitter) Status(ctx context.Context) (git.Status, error) {
	args := m.Called(ctx)
	return args.Get(0).(git.Status), args.Error(1)
}

// setupProcessorTest creates a test environment and returns cleanup function
func setupProcessorTest(t *testing.T) func() {
	testDir := t.TempDir()

	// Initialize git repo
	err := exec.Command("git", "init", testDir).Run()
	if err != nil {
		t.Fatalf("failed to initialize git repo: %v", err)
	}

	// Save original directory
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get current directory: %v", err)
	}

	// Change to test directory
	if err := os.Chdir(testDir); err != nil {
		t.Fatalf("failed to change directory: %v", err)
	}

	// Create test file
	err = os.WriteFile("main.go", []byte(`package main

func main() {
	println("Hello, World!")
}
`), 0644)
	assert.NoError(t, err)

	return func() {
		os.Chdir(origDir)
	}
}

func TestProcessorValidResponse(t *testing.T) {
	cleanup := setupProcessorTest(t)
	defer cleanup()

	// Create mock LLM client with valid response
	mockLLM := new(testLLMClient)
	mockLLM.On("GetPatch", mock.Anything, mock.Anything).Return(`{
		"commit": {"subject": "Add error handling"},
		"patches": [{
			"file": "main.go",
			"type": "replace",
			"fromLine": 3,
			"toLine": 4,
			"linesBefore": ["func main() {", "	println(\"Hello, World!\")", "}"],
			"linesAfter": ["func main() {", "	fmt.Println(\"Hello, World!\")", "}"],
			"content": "\tfmt.Println(\"Hello, World!\")"
		}]
	}`, nil)

	// Create mock validator that passes
	mockVal := new(testValidator)
	mockVal.On("Validate", mock.Anything).Return(nil)

	// Create mock git committer
	mockGit := new(testGitCommitter)
	mockGit.On("Commit", mock.Anything, mock.Anything).Return(nil)

	// Create processor config
	cfg := &workflow.ProcessorConfig{
		GitCommitter:    mockGit,
		Validator:       mockVal,
		LLMClient:       mockLLM,
		UserInteraction: workflow.NewDefaultInteraction(),
	}

	proc, err := workflow.NewProcessor(cfg)
	assert.NoError(t, err)

	err = proc.Process(context.Background(), "Add error handling")
	assert.NoError(t, err)

	mockLLM.AssertExpectations(t)
	mockVal.AssertExpectations(t)
	mockGit.AssertExpectations(t)
}

func TestProcessorLintFailure(t *testing.T) {
	cleanup := setupProcessorTest(t)
	defer cleanup()

	// Create mock LLM client with response that will fail lint
	mockLLM := new(testLLMClient)
	mockLLM.On("GetPatch", mock.Anything, mock.Anything).Return(`{
		"commit": {"subject": "Add invalid code"},
		"patches": [{
			"file": "main.go",
			"type": "replace",
			"fromLine": 3,
			"toLine": 4,
			"linesBefore": ["func main() {", "	println(\"Hello, World!\")", "}"],
			"linesAfter": ["func main() {", "	var x int = \"hello\"", "}"],
			"content": "\tvar x int = \"hello\""
		}]
	}`, nil)

	// Create mock validator that fails lint
	mockVal := new(testValidator)
	mockVal.On("Validate", mock.Anything).Return(fmt.Errorf("lint error: cannot use \"hello\" (type string) as type int"))

	// Create mock git committer
	mockGit := new(testGitCommitter)

	// Create processor config
	cfg := &workflow.ProcessorConfig{
		GitCommitter:    mockGit,
		Validator:       mockVal,
		LLMClient:       mockLLM,
		UserInteraction: workflow.NewDefaultInteraction(),
	}

	proc, err := workflow.NewProcessor(cfg)
	assert.NoError(t, err)

	err = proc.Process(context.Background(), "Add invalid code")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "lint error")

	mockLLM.AssertExpectations(t)
	mockVal.AssertExpectations(t)
	mockGit.AssertNotCalled(t, "Commit")
}

func TestProcessorTestFailure(t *testing.T) {
	cleanup := setupProcessorTest(t)
	defer cleanup()

	// Create mock LLM client with response that will fail tests
	mockLLM := new(testLLMClient)
	mockLLM.On("GetPatch", mock.Anything, mock.Anything).Return(`{
		"commit": {"subject": "Break tests"},
		"patches": [{
			"file": "main.go",
			"type": "replace",
			"fromLine": 3,
			"toLine": 4,
			"linesBefore": ["func main() {", "	println(\"Hello, World!\")", "}"],
			"linesAfter": ["func main() {", "	panic(\"oops\")", "}"],
			"content": "\tpanic(\"oops\")"
		}]
	}`, nil)

	// Create mock validator that fails tests
	mockVal := new(testValidator)
	mockVal.On("Validate", mock.Anything).Return(fmt.Errorf("test failure: panic: oops"))

	// Create mock git committer
	mockGit := new(testGitCommitter)

	// Create processor config
	cfg := &workflow.ProcessorConfig{
		GitCommitter:    mockGit,
		Validator:       mockVal,
		LLMClient:       mockLLM,
		UserInteraction: workflow.NewDefaultInteraction(),
	}

	proc, err := workflow.NewProcessor(cfg)
	assert.NoError(t, err)

	err = proc.Process(context.Background(), "Break tests")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "test failure")

	mockLLM.AssertExpectations(t)
	mockVal.AssertExpectations(t)
	mockGit.AssertNotCalled(t, "Commit")
}

func TestProcessorInvalidLineNumbers(t *testing.T) {
	cleanup := setupProcessorTest(t)
	defer cleanup()

	// Create mock LLM client with response containing invalid line numbers
	mockLLM := new(testLLMClient)
	mockLLM.On("GetPatch", mock.Anything, mock.Anything).Return(`{
		"commit": {"subject": "Invalid line numbers"},
		"patches": [{
			"file": "main.go",
			"type": "replace",
			"fromLine": 999,
			"toLine": 1000,
			"linesBefore": ["func main() {", "	println(\"Hello, World!\")", "}"],
			"linesAfter": ["func main() {", "	fmt.Println(\"Hello\")", "}"],
			"content": "\tfmt.Println(\"Hello\")"
		}]
	}`, nil)

	// Create mock validator
	mockVal := new(testValidator)

	// Create mock git committer
	mockGit := new(testGitCommitter)

	// Create processor config
	cfg := &workflow.ProcessorConfig{
		GitCommitter:    mockGit,
		Validator:       mockVal,
		LLMClient:       mockLLM,
		UserInteraction: workflow.NewDefaultInteraction(),
	}

	proc, err := workflow.NewProcessor(cfg)
	assert.NoError(t, err)

	err = proc.Process(context.Background(), "Invalid line numbers")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "invalid line range")

	mockLLM.AssertExpectations(t)
	mockVal.AssertNotCalled(t, "Validate")
	mockGit.AssertNotCalled(t, "Commit")
}

func TestProcessorInvalidJSON(t *testing.T) {
	cleanup := setupProcessorTest(t)
	defer cleanup()

	// Create mock LLM client with invalid JSON response
	mockLLM := new(testLLMClient)
	mockLLM.On("GetPatch", mock.Anything, mock.Anything).Return(`{
		"commit": {"subject": "Invalid JSON"},
		"patches": [{
			"file": "main.go",
			"type": "replace",
			"fromLine": 3,
			"toLine": 4,
			"linesBefore": ["func main() {", "	println(\"Hello, World!\")", "}"],
			"linesAfter": ["func main() {", "	fmt.Println(\"Hello\")", "}"],
			"content": "\tfmt.Println(\"Hello\")",,,
		}]
	}`, nil)

	// Create mock validator
	mockVal := new(testValidator)

	// Create mock git committer
	mockGit := new(testGitCommitter)

	// Create processor config
	cfg := &workflow.ProcessorConfig{
		GitCommitter:    mockGit,
		Validator:       mockVal,
		LLMClient:       mockLLM,
		UserInteraction: workflow.NewDefaultInteraction(),
	}

	proc, err := workflow.NewProcessor(cfg)
	assert.NoError(t, err)

	err = proc.Process(context.Background(), "Invalid JSON")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "invalid JSON")

	mockLLM.AssertExpectations(t)
	mockVal.AssertNotCalled(t, "Validate")
	mockGit.AssertNotCalled(t, "Commit")
}
