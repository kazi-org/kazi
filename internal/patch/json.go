package patch

import (
	"encoding/json"
	"fmt"
)

// UnmarshalJSON implements json.Unmarshaler for PatchSet
func (ps *PatchSet) UnmarshalJSON(data []byte) error {
	// Define a temporary struct to unmarshal into
	type tempPatch struct {
		File    string `json:"file"`
		Type    string `json:"type"`
		Content string `json:"content"`
	}
	type tempPatchSet struct {
		Patches []tempPatch   `json:"patches"`
		Commit  CommitMessage `json:"commit"`
	}

	// Unmarshal into temporary struct
	var temp tempPatchSet
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	// Validate and convert patches
	ps.Patches = make([]Chunk, len(temp.Patches))
	for i, p := range temp.Patches {
		// Validate required fields
		if p.File == "" {
			return fmt.Errorf("missing required field: file")
		}

		// Convert patch type
		var patchType PatchType
		switch p.Type {
		case "create":
			patchType = PatchCreate
		case "replace":
			patchType = PatchReplace
		case "delete":
			patchType = PatchDelete
		default:
			return fmt.Errorf("invalid patch type: %s", p.Type)
		}

		// Create chunk
		ps.Patches[i] = Chunk{
			File:    p.File,
			Type:    patchType,
			Content: p.Content,
		}
	}

	// Copy commit message
	ps.Commit = temp.Commit

	return nil
}
