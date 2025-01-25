// Package format provides formatting utilities for code context.
package format

import (
	"fmt"
	"go/ast"
	"go/printer"
	"go/token"
	"strings"

	"github.com/kazi-org/kazi/internal/contextstore/types"
	lstypes "github.com/kazi-org/kazi/internal/ls/types"
)

// formatCommonFields formats fields common to both SymbolDefinition and SymbolContext
func formatCommonFields(sb *strings.Builder, name, kind, docString, signature string) {
	sb.WriteString(fmt.Sprintf("Name: %s\n", name))
	sb.WriteString(fmt.Sprintf("Kind: %s\n", kind))

	if docString != "" {
		sb.WriteString(fmt.Sprintf("Documentation: %s\n", docString))
	}

	if signature != "" {
		sb.WriteString(fmt.Sprintf("Signature: %s\n", signature))
	}
}

// formatLocation formats a location field if present
func formatLocation(sb *strings.Builder, loc *lstypes.Location) {
	if loc != nil {
		sb.WriteString(fmt.Sprintf("Location: %s\n", loc.URI))
	}
}

// formatReferences formats a slice of references if present
func formatReferences(sb *strings.Builder, refs []*lstypes.Location) {
	if len(refs) > 0 {
		sb.WriteString("References:\n")
		for _, ref := range refs {
			if ref != nil {
				sb.WriteString(fmt.Sprintf("  - %s\n", ref.URI))
			}
		}
	}
}

// FormatSymbol formats a symbol definition into a human-readable string.
func FormatSymbol(def *lstypes.SymbolDefinition) string {
	if def == nil {
		return ""
	}

	var sb strings.Builder
	formatCommonFields(&sb, def.Name, string(def.Kind), def.DocString, def.Signature)
	formatReferences(&sb, def.References)
	return sb.String()
}

// FormatSymbolContext formats a symbol context into a human-readable string.
func FormatSymbolContext(ctx *types.SymbolContext) string {
	if ctx == nil {
		return ""
	}

	var sb strings.Builder
	formatCommonFields(&sb, ctx.Name, ctx.Kind, ctx.DocString, ctx.Signature)
	formatLocation(&sb, ctx.Location)
	formatReferences(&sb, ctx.References)
	return sb.String()
}

// FormatFileContext formats a file context into a human-readable string.
func FormatFileContext(ctx *types.FileContext) string {
	if ctx == nil {
		return ""
	}

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("File: %s\n", ctx.FilePath))

	if len(ctx.Symbols) > 0 {
		sb.WriteString("\nSymbols:\n")
		for _, sym := range ctx.Symbols {
			sb.WriteString(fmt.Sprintf("\n%s\n", FormatSymbolContext(sym)))
		}
	}

	return sb.String()
}

// FormatCodeContext formats a code context into a human-readable string.
func FormatCodeContext(ctx *types.CodeContext) string {
	if ctx == nil {
		return ""
	}

	var sb strings.Builder
	sb.WriteString("Code Context:\n")

	if len(ctx.Files) > 0 {
		sb.WriteString("\nFiles:\n")
		for _, file := range ctx.Files {
			sb.WriteString(fmt.Sprintf("\n%s\n", FormatFileContext(file)))
		}
	}

	return sb.String()
}

// FuncSignature returns a string representation of a function's signature.
func FuncSignature(fn *ast.FuncDecl) string {
	var buf strings.Builder
	fset := token.NewFileSet()

	// Format function declaration
	printer.Fprint(&buf, fset, fn)

	// Extract just the signature (remove body)
	sig := buf.String()
	if idx := strings.Index(sig, "{"); idx != -1 {
		sig = strings.TrimSpace(sig[:idx])
	}
	return sig
}

// ExtractMethodSet extracts method names from a symbol definition.
func ExtractMethodSet(def *lstypes.SymbolDefinition) []string {
	var methods []string
	if strings.Contains(def.Signature, "func") {
		parts := strings.Split(def.Signature, "func")
		for _, p := range parts[1:] {
			if name := strings.TrimSpace(strings.Split(p, "(")[0]); name != "" {
				methods = append(methods, name)
			}
		}
	}
	return methods
}

// ExtractImplementedInterfaces extracts interface names from a symbol's documentation.
func ExtractImplementedInterfaces(def *lstypes.SymbolDefinition) []string {
	var interfaces []string
	if strings.Contains(def.DocString, "implements") {
		parts := strings.Split(def.DocString, "implements")
		if len(parts) > 1 {
			ifaces := strings.Split(parts[1], ".")
			for _, iface := range ifaces {
				if name := strings.TrimSpace(iface); name != "" {
					interfaces = append(interfaces, name)
				}
			}
		}
	}
	return interfaces
}

// ExtractPackageName gets the package name from file content.
func ExtractPackageName(content string) string {
	if lines := strings.Split(content, "\n"); len(lines) > 0 {
		if pkgLine := strings.TrimSpace(lines[0]); strings.HasPrefix(pkgLine, "package ") {
			return strings.TrimPrefix(pkgLine, "package ")
		}
	}
	return "main" // default
}

// IsExported returns true if the symbol name is exported.
func IsExported(name string) bool {
	return strings.Title(name) == name
}
