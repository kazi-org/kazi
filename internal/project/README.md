# internal/project

Stores domain/config data in a single **Project** struct. 
Provides a **ProjectManager** interface to load/save or manipulate the project.

## Single Responsibility

- Only track project data (domain constraints, architecture, ephemeral logs, chunk references, progress).
- Avoid embedding advanced logic (like LLM calls or patch steps).

## Implementation Tips

- The default manager might use a YAML file ".kazi.yaml".
- A developer can write a custom manager that loads from multiple files or a DB.

