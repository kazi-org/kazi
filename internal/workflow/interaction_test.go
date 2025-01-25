package workflow

import (
	"bufio"
	"context"
	"strings"
	"testing"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/patch"
)

// mockInteraction implements UserInteraction for testing
type mockInteraction struct {
	responses []string
	index     int
}

func newMockInteraction(responses []string) *mockInteraction {
	return &mockInteraction{
		responses: responses,
	}
}

func (m *mockInteraction) PromptForChanges(ctx context.Context, changes *patch.PatchSet) (UserInteractionMode, *config.Prompt, error) {
	if m.index >= len(m.responses) {
		return ModeAbort, nil, nil
	}

	response := m.responses[m.index]
	m.index++

	switch response {
	case "yes", "y":
		return ModeYes, nil, nil
	case "no", "n":
		return ModeNo, nil, nil
	case "chat", "c":
		return ModeChat, &config.Prompt{Instructions: "modified prompt"}, nil
	case "abort", "a":
		return ModeAbort, nil, nil
	case "all":
		return ModeAll, nil, nil
	case "yolo":
		return ModeYolo, nil, nil
	default:
		return ModeAbort, nil, nil
	}
}

// testInteraction implements UserInteraction with a string reader for testing
type testInteraction struct {
	defaultInteraction
}

func newTestInteraction(input string) *testInteraction {
	return &testInteraction{
		defaultInteraction: defaultInteraction{
			reader: bufio.NewReader(strings.NewReader(input)),
		},
	}
}

func TestUserInteraction(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		wantMode    UserInteractionMode
		wantPrompt  *config.Prompt
		wantErr     bool
		errContains string
		patchSet    *patch.PatchSet
	}{
		{
			name:     "Accept changes",
			input:    "yes\n",
			wantMode: ModeYes,
			patchSet: &patch.PatchSet{
				Patches: []patch.Chunk{
					{
						File: "test.go",
						Type: patch.PatchCreate,
					},
				},
				Commit: patch.CommitMessage{
					Subject: "Test commit",
				},
			},
		},
		{
			name:     "Reject changes",
			input:    "no\n",
			wantMode: ModeNo,
			patchSet: &patch.PatchSet{
				Patches: []patch.Chunk{
					{
						File: "test.go",
						Type: patch.PatchCreate,
					},
				},
			},
		},
		{
			name:     "Chat mode",
			input:    "chat\nmodified prompt\n",
			wantMode: ModeChat,
			wantPrompt: &config.Prompt{
				Instructions: "modified prompt",
			},
			patchSet: &patch.PatchSet{
				Patches: []patch.Chunk{
					{
						File: "test.go",
						Type: patch.PatchCreate,
					},
				},
			},
		},
		{
			name:     "Abort operation",
			input:    "abort\n",
			wantMode: ModeAbort,
			patchSet: &patch.PatchSet{
				Patches: []patch.Chunk{
					{
						File: "test.go",
						Type: patch.PatchCreate,
					},
				},
			},
		},
		{
			name:     "Accept all changes",
			input:    "all\n",
			wantMode: ModeAll,
			patchSet: &patch.PatchSet{
				Patches: []patch.Chunk{
					{
						File: "test.go",
						Type: patch.PatchCreate,
					},
				},
			},
		},
		{
			name:     "YOLO mode",
			input:    "yolo\n",
			wantMode: ModeYolo,
			patchSet: &patch.PatchSet{
				Patches: []patch.Chunk{
					{
						File: "test.go",
						Type: patch.PatchCreate,
					},
				},
			},
		},
		{
			name:     "Invalid choice then valid",
			input:    "invalid\nyes\n",
			wantMode: ModeYes,
			patchSet: &patch.PatchSet{
				Patches: []patch.Chunk{
					{
						File: "test.go",
						Type: patch.PatchCreate,
					},
				},
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			interaction := newTestInteraction(tc.input)
			mode, prompt, err := interaction.PromptForChanges(context.Background(), tc.patchSet)

			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error but got nil")
				}
				if tc.errContains != "" && !strings.Contains(err.Error(), tc.errContains) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if mode != tc.wantMode {
				t.Errorf("mode = %v, want %v", mode, tc.wantMode)
			}

			if tc.wantPrompt != nil {
				if prompt == nil {
					t.Fatal("expected prompt but got nil")
				}
				if prompt.Instructions != tc.wantPrompt.Instructions {
					t.Errorf("prompt = %q, want %q", prompt.Instructions, tc.wantPrompt.Instructions)
				}
			} else if prompt != nil {
				t.Errorf("prompt = %v, want nil", prompt)
			}
		})
	}
}
