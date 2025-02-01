package memory

import (
	"context"
	"errors"
	"strings"
)

// MemoryAggregator composes smaller interfaces, implementing code/doc/log retrieval 
// plus a fallback to the underlying DB if needed.
type MemoryAggregator struct {
	Code   CodeSource
	Doc    DocSource
	Log    LogSource
}

// GetMemory attempts to figure out if query is "code:", "doc:", "log:" 
// then calls the relevant interface. 
// If no prefix matches, we return an error or empty string.
func (ma *MemoryAggregator) GetMemory(ctx context.Context, query string) (string, error) {
	switch {
	case strings.HasPrefix(query, "code:"):
		if ma.Code == nil {
			return "", errors.New("code source not configured")
		}
		return ma.Code.GetCode(ctx, strings.TrimPrefix(query, "code:"))
	case strings.HasPrefix(query, "doc:"):
		if ma.Doc == nil {
			return "", errors.New("doc source not configured")
		}
		return ma.Doc.GetDoc(ctx, strings.TrimPrefix(query, "doc:"))
	case strings.HasPrefix(query, "log:"):
		if ma.Log == nil {
			return "", errors.New("log source not configured")
		}
		return ma.Log.GetLog(ctx, strings.TrimPrefix(query, "log:"))
	default:
		return "", errors.New("unknown memory query prefix")
	}
}
