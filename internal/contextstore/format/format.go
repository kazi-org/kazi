// Package format provides utilities for formatting Go code elements.
package format

import (
	"fmt"
	"go/ast"
	"go/printer"
	"go/token"
	"strings"

	gols "github.com/kazi-org/kazi/internal/ls/gols"
)

// FuncType formats a function type into a string representation.
// It handles parameters, results, and their names in a consistent format.
func FuncType(ft *ast.FuncType) string {
	var params, results []string

	// Format parameters
	if ft.Params != nil {
		for _, p := range ft.Params.List {
			param := Node(p.Type)
			if len(p.Names) > 0 {
				names := make([]string, len(p.Names))
				for i, name := range p.Names {
					names[i] = name.Name
				}
				param = fmt.Sprintf("%s %s", strings.Join(names, ", "), param)
			}
			params = append(params, param)
		}
	}

	// Format results
	if ft.Results != nil {
		for _, r := range ft.Results.List {
			result := Node(r.Type)
			if len(r.Names) > 0 {
				names := make([]string, len(r.Names))
				for i, name := range r.Names {
					names[i] = name.Name
				}
				result = fmt.Sprintf("%s %s", strings.Join(names, ", "), result)
			}
			results = append(results, result)
		}
	}

	// Combine into signature
	signature := fmt.Sprintf("(%s)", strings.Join(params, ", "))
	if len(results) > 0 {
		if len(results) == 1 && !strings.Contains(results[0], " ") {
			signature += " " + results[0]
		} else {
			signature += fmt.Sprintf(" (%s)", strings.Join(results, ", "))
		}
	}
	return signature
}

// Node formats an AST node into a string representation.
// It handles various Go types including pointers, arrays, maps, etc.
func Node(node ast.Node) string {
	switch n := node.(type) {
	case *ast.Ident:
		return n.Name
	case *ast.StarExpr:
		return "*" + Node(n.X)
	case *ast.ArrayType:
		if n.Len == nil {
			return "[]" + Node(n.Elt)
		}
		return fmt.Sprintf("[%s]%s", Node(n.Len), Node(n.Elt))
	case *ast.MapType:
		return fmt.Sprintf("map[%s]%s", Node(n.Key), Node(n.Value))
	case *ast.InterfaceType:
		return "interface{}"
	case *ast.StructType:
		return "struct{}"
	case *ast.BasicLit:
		return n.Value
	case *ast.SelectorExpr:
		return fmt.Sprintf("%s.%s", Node(n.X), n.Sel.Name)
	default:
		return fmt.Sprintf("<%T>", node)
	}
}

// FuncSignature returns a string representation of a function's signature.
// It includes receiver, name, parameters, and results in a consistent format.
func FuncSignature(fn *ast.FuncDecl) string {
	var buf strings.Builder
	buf.WriteString("func ")

	// Format receiver if present
	if fn.Recv != nil {
		buf.WriteByte('(')
		if len(fn.Recv.List) > 0 {
			if len(fn.Recv.List[0].Names) > 0 {
				buf.WriteString(fn.Recv.List[0].Names[0].Name)
				buf.WriteByte(' ')
			}
			printer.Fprint(&buf, token.NewFileSet(), fn.Recv.List[0].Type)
		}
		buf.WriteString(") ")
	}

	// Add function name
	buf.WriteString(fn.Name.Name)

	// Format parameters
	buf.WriteByte('(')
	if fn.Type.Params != nil && len(fn.Type.Params.List) > 0 {
		for i, param := range fn.Type.Params.List {
			if i > 0 {
				buf.WriteString(", ")
			}
			if len(param.Names) > 0 {
				for j, name := range param.Names {
					if j > 0 {
						buf.WriteString(", ")
					}
					buf.WriteString(name.Name)
				}
				buf.WriteByte(' ')
			}
			printer.Fprint(&buf, token.NewFileSet(), param.Type)
		}
	}
	buf.WriteByte(')')

	// Format results
	if fn.Type.Results != nil {
		buf.WriteByte(' ')
		if len(fn.Type.Results.List) > 1 || (len(fn.Type.Results.List) == 1 && len(fn.Type.Results.List[0].Names) > 0) {
			buf.WriteString("(")
		}
		for i, result := range fn.Type.Results.List {
			if i > 0 {
				buf.WriteString(", ")
			}
			if len(result.Names) > 0 {
				for j, name := range result.Names {
					if j > 0 {
						buf.WriteString(", ")
					}
					buf.WriteString(name.Name)
				}
				buf.WriteByte(' ')
			}
			printer.Fprint(&buf, token.NewFileSet(), result.Type)
		}
		if len(fn.Type.Results.List) > 1 || (len(fn.Type.Results.List) == 1 && len(fn.Type.Results.List[0].Names) > 0) {
			buf.WriteString(")")
		}
	}
	return buf.String()
}

// ExtractMethodSet extracts method names from a symbol definition.
// It parses the signature to find method definitions.
func ExtractMethodSet(def *gols.SymbolDefinition) []string {
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
// It looks for "implements" keyword in the docstring.
func ExtractImplementedInterfaces(def *gols.SymbolDefinition) []string {
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
	pkgName := "main" // default
	if lines := strings.Split(content, "\n"); len(lines) > 0 {
		if pkgLine := strings.TrimSpace(lines[0]); strings.HasPrefix(pkgLine, "package ") {
			pkgName = strings.TrimPrefix(pkgLine, "package ")
		}
	}
	return pkgName
}

// IsExported returns true if the symbol name is exported.
func IsExported(name string) bool {
	return strings.Title(name) == name
}
