package patch

import (
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/kazi-org/kazi/internal/log"
)

// tempPatch is used for initial JSON unmarshaling
type tempPatch struct {
	File        string   `json:"file"`
	Type        string   `json:"type"`
	Content     string   `json:"content"`
	FromLine    int      `json:"fromLine"`
	ToLine      int      `json:"toLine"`
	LinesBefore []string `json:"linesBefore"`
	LinesAfter  []string `json:"linesAfter"`
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

// unescapeContent unescapes special characters in content
func unescapeContent(content string) (string, error) {
	// Use Go's string unquoting to handle escapes
	unquoted, err := strconv.Unquote(`"` + content + `"`)
	if err != nil {
		return "", fmt.Errorf("unescape content: %w", err)
	}
	return unquoted, nil
}

// UnmarshalJSON implements json.Unmarshaler for PatchSet
func (ps *PatchSet) UnmarshalJSON(data []byte) error {
	log.Debug("Unmarshaling JSON response of length %d", len(data))
	log.Debug("Raw JSON:\n%s", string(data))

	// Unmarshal into temporary struct
	var temp tempPatchSet
	if err := json.Unmarshal(data, &temp); err != nil {
		log.Debug("Failed to unmarshal JSON: %v", err)
		log.Debug("JSON parsing error details: %+v", err)
		return err
	}
	log.Debug("Successfully unmarshaled JSON with %d patches", len(temp.Patches))

	// Validate and convert patches
	ps.Patches = make([]Chunk, len(temp.Patches))
	for i, p := range temp.Patches {
		log.Debug("Processing patch %d:", i)
		log.Debug("  File: %s", p.File)
		log.Debug("  Type: %s", p.Type)
		log.Debug("  Lines: %d-%d", p.FromLine, p.ToLine)
		log.Debug("  Content length: %d", len(p.Content))
		log.Debug("  LinesBefore: %v", p.LinesBefore)
		log.Debug("  LinesAfter: %v", p.LinesAfter)

		// Validate required fields
		if p.File == "" {
			log.Debug("Patch %d missing required field: file", i)
			return fmt.Errorf("missing required field: file")
		}

		// Convert patch type
		patchType, ok := patchTypeMap[p.Type]
		if !ok {
			log.Debug("Patch %d has invalid type: %s", i, p.Type)
			return fmt.Errorf("invalid patch type: %s", p.Type)
		}

		// Validate line numbers for replace patches
		if patchType == PatchReplace {
			if p.FromLine <= 0 || p.ToLine < p.FromLine {
				log.Debug("Patch %d has invalid line range: from=%d, to=%d", i, p.FromLine, p.ToLine)
				return fmt.Errorf("invalid line range: from=%d, to=%d", p.FromLine, p.ToLine)
			}
			// Validate lines
			if len(p.LinesBefore) == 0 {
				log.Debug("Patch %d missing required field: linesBefore", i)
				return fmt.Errorf("missing required field: linesBefore")
			}
			if len(p.LinesAfter) == 0 {
				log.Debug("Patch %d missing required field: linesAfter", i)
				return fmt.Errorf("missing required field: linesAfter")
			}
		}

		// Validate content for create and replace patches
		if (patchType == PatchCreate || patchType == PatchReplace) && p.Content == "" {
			log.Debug("Patch %d missing required field: content", i)
			return fmt.Errorf("missing required field: patches[%d].content", i)
		}

		// Unescape content
		content := p.Content
		if content != "" {
			log.Debug("Patch %d raw content:\n%s", i, content)
			unescaped, err := unescapeContent(content)
			if err != nil {
				log.Debug("Patch %d failed to unescape content: %v", i, err)
				log.Debug("Failed content: %q", content)
				return fmt.Errorf("patch %d: %w", i, err)
			}
			content = unescaped
			log.Debug("Patch %d unescaped content:\n%s", i, content)
		}

		// Create chunk
		ps.Patches[i] = Chunk{
			File:        p.File,
			Type:        patchType,
			Content:     content,
			FromLine:    p.FromLine,
			ToLine:      p.ToLine,
			LinesBefore: p.LinesBefore,
			LinesAfter:  p.LinesAfter,
		}
		log.Debug("Patch %d processed successfully", i)
	}

	// Copy commit message
	ps.Commit = temp.Commit
	log.Debug("Commit message: %+v", temp.Commit)

	return nil
}
