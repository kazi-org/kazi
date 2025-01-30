// Package vision defines the Vision Contract: a high-level product requirement
// or "must-have" constraints that all generated code must respect.

package vision

// Contract represents the "Vision Contract": a description of what the
// final software must accomplish, including constraints that guide code generation.
type Contract struct {
	Name        string            // e.g. "Payment Gateway Integration"
	Description string            // High-level summary or objective
	Constraints map[string]string // e.g. {"compliance": "PCI-DSS", "language": "Go"}
}

// Loader optionally reads a Contract from a file or external data.
type Loader interface {
	LoadContract(pathOrData string) (*Contract, error)
}
