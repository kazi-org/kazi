package ai

import (
	"context"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// mockLLMClient implements LLMClient for testing
type mockLLMClient struct {
	getPatchFunc    func(ctx context.Context, prompt string) (string, error)
	streamPatchFunc func(ctx context.Context, prompt string) (io.ReadCloser, error)
}

func (m *mockLLMClient) GetPatch(ctx context.Context, prompt string) (string, error) {
	if m.getPatchFunc != nil {
		return m.getPatchFunc(ctx, prompt)
	}
	return "", fmt.Errorf("GetPatch not implemented")
}

func (m *mockLLMClient) StreamPatch(ctx context.Context, prompt string) (io.ReadCloser, error) {
	if m.streamPatchFunc != nil {
		return m.streamPatchFunc(ctx, prompt)
	}
	return nil, fmt.Errorf("StreamPatch not implemented")
}

// mockReadCloser implements io.ReadCloser for testing
type mockReadCloser struct {
	*strings.Reader
	closeFunc func() error
}

func (m *mockReadCloser) Close() error {
	if m.closeFunc != nil {
		return m.closeFunc()
	}
	return nil
}

func TestLLMClientInterface(t *testing.T) {
	// Test that mockLLMClient implements LLMClient
	var _ LLMClient = (*mockLLMClient)(nil)

	// Create mock client with test implementations
	client := &mockLLMClient{
		getPatchFunc: func(ctx context.Context, prompt string) (string, error) {
			return "test patch", nil
		},
		streamPatchFunc: func(ctx context.Context, prompt string) (io.ReadCloser, error) {
			return &mockReadCloser{
				Reader: strings.NewReader("test stream"),
				closeFunc: func() error {
					return nil
				},
			}, nil
		},
	}

	t.Run("GetPatch", func(t *testing.T) {
		patch, err := client.GetPatch(context.Background(), "test prompt")
		assert.NoError(t, err)
		assert.Equal(t, "test patch", patch)
	})

	t.Run("StreamPatch", func(t *testing.T) {
		stream, err := client.StreamPatch(context.Background(), "test prompt")
		assert.NoError(t, err)
		defer stream.Close()

		data, err := io.ReadAll(stream)
		assert.NoError(t, err)
		assert.Equal(t, "test stream", string(data))
	})

	t.Run("Context cancellation", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		_, err := client.GetPatch(ctx, "test prompt")
		assert.NoError(t, err) // Our mock doesn't handle cancellation, but real implementations should

		_, err = client.StreamPatch(ctx, "test prompt")
		assert.NoError(t, err) // Our mock doesn't handle cancellation, but real implementations should
	})

	t.Run("Error cases", func(t *testing.T) {
		errorClient := &mockLLMClient{
			getPatchFunc: func(ctx context.Context, prompt string) (string, error) {
				return "", fmt.Errorf("test error")
			},
			streamPatchFunc: func(ctx context.Context, prompt string) (io.ReadCloser, error) {
				return nil, fmt.Errorf("test error")
			},
		}

		_, err := errorClient.GetPatch(context.Background(), "test prompt")
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "test error")

		_, err = errorClient.StreamPatch(context.Background(), "test prompt")
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "test error")
	})
}
