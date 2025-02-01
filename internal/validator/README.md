# internal/validator

Renamed from "validation". Provides a pipeline for build/test (and optionally security scanning) checks.

## Single Responsibility

- Only checks code correctness or security. 
- Returns a `ValidationResult` capturing success or error details.

