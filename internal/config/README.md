# config

Provides a Kubernetes-style manifest loader that merges:
- **Vision Contract** fields (Name, Description, Constraints)
- **KaziConfig** fields (workspace, lint/test commands)
- plus top-level metadata (apiVersion, kind, etc.)

A single `.kazi.yaml` can define both the product vision and operational config 
for Kazi in one place.
