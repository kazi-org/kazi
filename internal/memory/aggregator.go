package memory

import (
	"context"
	"errors"
	"strings"
)

// MemoryAggregator composes code/doc/log sources if you want a single aggregator approach.
type MemoryAggregator struct {
	Code CodeSource
	Doc  DocSource
	Log  LogSource
}

// GetMemory is a single aggregator method, parse query prefix for code/doc/log
func (ma *MemoryAggregator) GetMemory(ctx context.Context, query string) (string, error) {
	switch {
	case strings.HasPrefix(query, "code:"):
		if ma.Code == nil {
			return "", errors.New("code source is nil")
		}
		return ma.Code.GetCode(ctx, strings.TrimPrefix(query, "code:"))
	case strings.HasPrefix(query, "doc:"):
		if ma.Doc == nil {
			return "", errors.New("doc source is nil")
		}
		return ma.Doc.GetDoc(ctx, strings.TrimPrefix(query, "doc:"))
	case strings.HasPrefix(query, "log:"):
		if ma.Log == nil {
			return "", errors.New("log source is nil")
		}
		return ma.Log.GetLog(ctx, strings.TrimPrefix(query, "log:"))
	default:
		return "", errors.New("unrecognized prefix for memory aggregator")
	}
}
