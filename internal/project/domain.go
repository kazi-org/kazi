// domain.go
//
// Manages domain-level (vision) data: the Contract describing
// what the software is meant to achieve and constraints it must respect.

package project

// Contract represents the high-level business or product constraints.
type Contract struct {
	// Name is the short name or label for the product vision.
	Name string

	// Description is a longer summary of what the product/feature is about.
	Description string

	// Constraints is a key-value map of domain constraints (e.g., compliance: "PCI-DSS", language: "Go").
	Constraints map[string]string
}

// DomainManager is a specialized interface for loading or updating the Contract.
// You can replace or extend its methods without changing existing code.
type DomainManager interface {
	// LoadContract retrieves the domain contract from a file,
	// remote source, or direct data structure.
	LoadContract(pathOrData string) (*Contract, error)

	// UpdateContract modifies existing contract data (e.g., adding new constraints).
	UpdateContract(c *Contract) error
}
