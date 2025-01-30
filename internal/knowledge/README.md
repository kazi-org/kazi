# knowledge

Tracks historical records of patch attempts, successes, and failures. 
This can be used for analytics or for feeding improvements back into 
the code generation pipeline.

## Key Types

- **Store**: An interface for logging success/failure events.

Integration: The coordinator can call `Store.RecordSuccess` after a 
patch is validated and committed, or `Store.RecordFailure` if it fails.
