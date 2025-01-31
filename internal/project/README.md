# project

**Purpose**: The `project` package merges all high-level data about a Kazi-managed software project:

1. **Domain** (vision/contract): Name, description, compliance constraints.  
2. **Architecture** (blueprint): Modules, interfaces, methods.  
3. **Config**: Operational settings (workspace path, lint/test commands).  
4. **Doc Management**: Reading/writing memory bank `.md` files for project context.  
5. **Ephemeral Logs**: Tracking short-lived logs like patch successes/failures if desired.  
6. **Chunking**: Optionally retrieving code slices or analyzing them with concurrency.

## Package Layout

- **domain.go**: Holds the domain-level `Contract` with name/desc/constraints.  
- **architecture.go**: Contains blueprint data (`ModuleSpec`, `InterfaceSpec`).  
- **config.go**: Operational configuration fields (workspace, lint/test commands).  
- **doc_manager.go**: Reading/writing `.md` docs for self-documentation or “memory bank.”  
- **ephemeral_logs.go**: Minimal ephemeral log system to record patch attempts or general messages.  
- **chunk_provider.go**: Illustrative concurrency-based code chunk retrieval.  
- **project.go**: The main `Project` struct merges domain, architecture, config, plus optional references.  
- **manager.go**: Defines smaller specialized interfaces (`DomainManager`, `ConfigManager`, `DocManager`, `EphemeralLog`, `ChunkProvider`) and a `ProjectManager` that composes them.

## Design Principles

- **Single Responsibility**: Each file covers one concern (domain, config, docs, logs, chunking).  
- **Open-Closed**: Add new doc types or log strategies without changing existing types.  
- **Liskov Substitution**: If you create new `DocManager` or `EphemeralLog` implementations, the rest of the system still works.  
- **Interface Segregation**: Instead of one huge interface, we have specialized ones for domain, config, docs, logs, chunking.  
- **Dependency Inversion**: The final `ProjectManager` references these smaller interfaces abstractly rather than tying to specific implementations.  
- **Composition over Inheritance**: We embed or hold references to sub-managers; no big inheritance trees.  
- **Concurrency**: The doc manager or chunk provider can use goroutines/channels to read/write data in parallel.  
- **Error Handling**: All methods return `error` where something might fail.  
- **Clear Documentation**: Each interface and struct is docstringed for clarity.

## Usage

1. **Implement** or use the provided defaults for each specialized interface (`DomainManager`, `DocManager`, etc.).  
2. **Assemble** a `ProjectManager` that composes them.  
3. **Load** your project from a YAML or database.  
4. **Optionally** use concurrency in docs or chunk-based code retrieval.  
5. **Inject** the resulting `Project` (plus doc/log references) into your coordinator.

This makes your entire project context available in one cohesive package.
