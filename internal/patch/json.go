package patch

import (
	"encoding/json"
	"fmt"
)

// tempPatch is used for initial JSON unmarshaling
type tempPatch struct {
	File     string `json:"file"`
	Type     string `json:"type"`
	Content  string `json:"content"`
	FromLine int    `json:"fromLine"`
	ToLine   int    `json:"toLine"`
}

// tempPatchSet is used for initial JSON unmarshaling
type tempPatchSet struct {
	Patches []tempPatch   `json:"patches"`
	Commit  CommitMessage `json:"commit"`
}

// patchTypeMap maps string types to PatchType enum
var patchTypeMap = map[string]PatchType{
	"create":  PatchCreate,
	"replace": PatchReplace,
	"delete":  PatchDelete,
}

// UnmarshalJSON implements json.Unmarshaler for PatchSet
func (ps *PatchSet) UnmarshalJSON(data []byte) error {
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
		patchType, ok := patchTypeMap[p.Type]
		if !ok {
			return fmt.Errorf("invalid patch type: %s", p.Type)
		}

		// Validate line numbers for replace patches
		if patchType == PatchReplace {
			if p.FromLine <= 0 || p.ToLine < p.FromLine {
				return fmt.Errorf("invalid line range: from=%d, to=%d", p.FromLine, p.ToLine)
			}
		}

		// Create chunk
		ps.Patches[i] = Chunk{
			File:     p.File,
			Type:     patchType,
			Content:  p.Content,
			FromLine: p.FromLine,
			ToLine:   p.ToLine,
		}
	}

	// Copy commit message
	ps.Commit = temp.Commit

	return nil
}
