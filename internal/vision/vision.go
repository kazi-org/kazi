// internal/vision/vision.go
//
// Package vision defines the Vision Contract which specifies the high-level requirements
// and constraints that guide the code generation process. This contract ensures that
// all generated code aligns with key business objectives and compliance needs.
package vision

// Contract represents the Vision Contract: a description of the intended software,
// including its objectives and constraints (e.g., compliance requirements).
type Contract struct {
	Name        string            // Name of the vision, e.g., "Payment Gateway Integration"
	Description string            // High-level summary of the product requirements
	Constraints map[string]string // Constraints (e.g., {"compliance": "PCI-DSS", "language": "Go"})
}
