package workflow

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/fatih/color"
	"github.com/kazi-org/kazi/internal/patch"
)

// defaultInteraction is the default implementation of UserInteraction
type defaultInteraction struct {
	reader *bufio.Reader
}

// NewDefaultInteraction creates a new default user interaction
func NewDefaultInteraction() UserInteraction {
	return &defaultInteraction{
		reader: bufio.NewReader(os.Stdin),
	}
}

// displayColoredDiff shows a colored diff of the changes
func (d *defaultInteraction) displayColoredDiff(changes *patch.PatchSet) {
	// Create color config with default colors
	red := color.New(color.FgRed)
	green := color.New(color.FgGreen)
	blue := color.New(color.FgBlue)
	bold := color.New(color.Bold)

	// Display each patch
	for _, p := range changes.Patches {
		// Print file header
		bold.Printf("diff --git a/%s b/%s\n", p.File, p.File)

		// Print file mode changes based on patch type
		switch p.Type {
		case "create":
			blue.Println("new file mode 100644")
		case "delete":
			blue.Println("deleted file mode 100644")
		case "modify":
			blue.Println("modified file mode 100644")
		}

		// Print file paths
		blue.Printf("--- a/%s\n", p.File)
		blue.Printf("+++ b/%s\n", p.File)

		// Print content changes with proper diff markers
		if p.Type == "create" {
			// For new files, show all lines as added
			for _, line := range strings.Split(p.Content, "\n") {
				green.Printf("+%s\n", line)
			}
		} else if p.Type == "delete" {
			// For deleted files, show all lines as removed
			content, err := os.ReadFile(p.File)
			if err == nil {
				for _, line := range strings.Split(string(content), "\n") {
					red.Printf("-%s\n", line)
				}
			}
		} else if p.Type == "replace" {
			// For modified files, show the diff
			content, err := os.ReadFile(p.File)
			if err == nil {
				lines := strings.Split(string(content), "\n")

				// Show context before
				if len(p.LinesBefore) > 0 {
					for _, line := range p.LinesBefore {
						fmt.Printf(" %s\n", line)
					}
				}

				// Show lines being removed
				for i := p.FromLine - 1; i < p.ToLine && i < len(lines); i++ {
					red.Printf("-%s\n", lines[i])
				}

				// Show lines being added
				for _, line := range strings.Split(p.Content, "\n") {
					green.Printf("+%s\n", line)
				}

				// Show context after
				if len(p.LinesAfter) > 0 {
					for _, line := range p.LinesAfter {
						fmt.Printf(" %s\n", line)
					}
				}
			}
		}
		fmt.Println()
	}
}

// PromptForChanges asks the user to accept or reject changes
func (d *defaultInteraction) PromptForChanges(ctx context.Context, changes *patch.PatchSet) (UserInteractionMode, string, error) {
	// Display colored diff
	d.displayColoredDiff(changes)

	// Show commit message
	fmt.Printf("\nProposed commit message:\n")
	fmt.Printf("%s\n", changes.Commit.Subject)
	if changes.Commit.Body != "" {
		fmt.Printf("\n%s\n", changes.Commit.Body)
	}

	// Show options
	fmt.Println("\nOptions:")
	fmt.Println("- yes    : accept current changes")
	fmt.Println("- no     : reject current changes")
	fmt.Println("- chat   : modify the prompt and try again")
	fmt.Println("- quit   : quit the entire operation")
	fmt.Println("- all    : accept all changes in current prompt")
	fmt.Println("- yolo   : accept all changes in all prompts")

	for {
		select {
		case <-ctx.Done():
			return 0, "", ctx.Err()
		default:
			fmt.Print("\nYour choice: ")
			input, err := d.reader.ReadString('\n')
			if err != nil {
				return 0, "", fmt.Errorf("read user input: %w", err)
			}

			input = strings.TrimSpace(strings.ToLower(input))
			switch input {
			case "yes", "y":
				return ModeYes, "", nil
			case "no", "n":
				return ModeNo, "", nil
			case "chat", "c":
				fmt.Print("Enter new prompt: ")
				promptStr, err := d.reader.ReadString('\n')
				if err != nil {
					return 0, "", fmt.Errorf("read prompt: %w", err)
				}
				return ModeChat, strings.TrimSpace(promptStr), nil
			case "quit", "q":
				return ModeAbort, "", nil
			case "all":
				return ModeAll, "", nil
			case "yolo":
				return ModeYolo, "", nil
			default:
				fmt.Println("Invalid choice. Please try again.")
			}
		}
	}
}
