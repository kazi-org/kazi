# internal/memory

Handles code/doc/log retrieval, each via a single-responsibility interface:

- **CodeSource**: `GetCode(ctx, query string) (string, error)`
- **DocSource**: `GetDoc(ctx, query string) (string, error)`
- **LogSource**: `GetLog(ctx, query string) (string, error)`

Then we can have an **aggregator** (`MemoryAggregator`) that composes them 
if the coordinator only calls one method.

## Sub-package `db/`
Defines an abstract interface for an embedded vector DB (like `chromem-go`), 
so we can store embeddings and do approximate or exact similarity search.

