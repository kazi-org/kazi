// file_manager.go
//
// Provides a FileManager interface so the patch logic depends on an abstraction
// rather than direct file operations. We can swap a memory-based manager for testing
// or use remote storage.

package patch

import "fmt"

// FileManager allows reading/writing files, checking existence, etc., while
// letting the patch logic remain abstract from actual file APIs.
type FileManager interface {
	ReadFile(path string) ([]byte, error)
	WriteFile(path string, data []byte) error
	DeleteFile(path string) error
	Exists(path string) (bool, error)
	CreateDirForFile(path string) error
}

// ExampleFileManager is a naive OS-based FileManager. In real usage, you'd add concurrency
// or specialized error handling, or rely on "os", "io/ioutil", etc.
type ExampleFileManager struct{}

func (fm *ExampleFileManager) ReadFile(path string) ([]byte, error) {
	return nil, fmt.Errorf("not implemented")
}

func (fm *ExampleFileManager) WriteFile(path string, data []byte) error {
	return fmt.Errorf("not implemented")
}

func (fm *ExampleFileManager) DeleteFile(path string) error {
	return fmt.Errorf("not implemented")
}

func (fm *ExampleFileManager) Exists(path string) (bool, error) {
	return false, fmt.Errorf("not implemented")
}

func (fm *ExampleFileManager) CreateDirForFile(path string) error {
	return fmt.Errorf("not implemented")
}
