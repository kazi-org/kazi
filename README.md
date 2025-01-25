# Kazi

Kazi is an AI-powered coding assistant that helps you write, review, and maintain Go code. It integrates with your development workflow to provide intelligent code suggestions and automated refactoring.

## Features

- AI-powered code assistance
- Language Server Protocol (LSP) integration
- Automated code analysis and refactoring
- Interactive code review workflow
- Configurable validation rules
- Context-aware code understanding

## Installation

```bash
go install github.com/kazi-org/kazi/cmd/kazi@latest
```

## Configuration

Create a `.kazi.yaml` file in your project root:

```yaml
apiVersion: kazi.io/v1
kind: Config
metadata:
  name: my-project
spec:
  global:
    workspace: .
    languageServer:
      name: gopls
      command: gopls
      timeout: 30s
    lintCommand: golangci-lint run
    testCommand: go test ./...
  rules:
    - Give each type a single, well-defined responsibility (Single Responsibility)
    - Extend behavior by adding new types or methods rather than modifying existing code (Open-Closed)
    - Break larger interfaces into smaller, specialized ones (Interface Segregation)
  prompts:
    - "Review this code for SOLID principles"
    - "Optimize this function for performance"
    - "Add tests for this package"
```

### Configuration Fields

- `global`: Global settings for the project
  - `workspace`: Root directory of your project
  - `languageServer`: LSP configuration
    - `name`: Name of the language server
    - `command`: Command to start the language server
    - `timeout`: Timeout for LSP operations
  - `lintCommand`: Command to run linter
  - `testCommand`: Command to run tests
- `rules`: List of coding rules to enforce
- `prompts`: List of predefined prompts for common tasks

## Usage

1. Navigate to your Go project directory:
```bash
cd your-project
```

2. Run Kazi with a prompt:
```bash
kazi "Optimize this function for performance"
```

3. Review and approve suggested changes:
- `y` or `yes`: Accept changes
- `n` or `no`: Reject changes
- `c` or `chat`: Modify the prompt
- `a` or `abort`: Cancel operation
- `all`: Accept all changes
- `yolo`: Accept all changes without confirmation

## Development

### Prerequisites

- Go 1.21 or later
- gopls (Go language server)
- golangci-lint

### Building from Source

```bash
git clone https://github.com/kazi-org/kazi.git
cd kazi
go build ./cmd/kazi
```

### Running Tests

```bash
go test ./...
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.