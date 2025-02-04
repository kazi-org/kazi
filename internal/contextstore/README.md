Below is a sample high‐level design for a Go package that stores and retrieves the most relevant context from a large codebase. It draws inspiration from systems like **Chroma** (for chunked, retrievable data storage) and **Aider** (for building a “repo map” and partial retrieval). The idea is to give an LLM enough context to propose or patch code without hallucinating new features or duplicating existing ones, and to keep track of each “fix attempt” so the LLM can see when it is stuck.

---

## Overview

We want a package that:

1. **Indexes** a large codebase so we can retrieve the relevant fragments for a given query or file path.
2. **Stores** logs of LLM interactions, including “fix attempts” and their outcomes.
3. **Supports** an “ask for more info” flow so the LLM can request additional context if the returned snippets are insufficient.
4. **Keeps** an idempotent record of progress and repeated steps, so the LLM does not re‐introduce or re‐attempt the same solution unnecessarily.
5. **Avoids** duplication of existing code and “hallucinated” new features by always referencing the canonical existing data.

The design can be broken down into the following pieces:

1. **Repository Map** – A representation of the entire codebase (files, dependencies, major functions/classes).  
2. **Index and Chunk Store** – A system for storing large chunks (e.g., entire files or code blocks) in a way that can be searched quickly.  
3. **Querying and Retrieval** – A retrieval API that takes a query (e.g., an LLM prompt or a reference to a file that needs patching) and returns the relevant code blocks.  
4. **Activity Log / Fix Attempts** – A subsystem that tracks each “attempt” to fix or add code, along with success/failure notes.  
5. **Session / Task Management** – An idempotent way to track a “session” or “task” so that repeated queries about the same topic return consistent data.

Below is an example of how these pieces might fit together in Go.

---

## Package Layout

A possible directory layout for the package might look like:

```
contextstore/
  ├── store.go         # Core store interface & implementations (e.g. in-memory, local DB)
  ├── index.go         # Building & querying the code index (file paths, embeddings, etc.)
  ├── chunker.go       # Logic for splitting files into retrievable “chunks”
  ├── retrieval.go     # Retrieval logic that uses the index
  ├── activitylog.go   # Logs each fix attempt, tracks successes/failures
  ├── session.go       # Tracks session state, progress, idempotent operations
  ├── spec.go          # Defines how the system ensures code changes follow the “documented specification”
  └── ...
```

You might also store any schema definitions (if you use a database) or utility code in subdirectories.

---

## Data Structures

### 1. Repository Map

Represents the high‐level structure of the codebase:

```go
// RepoMap describes each file in the repo, plus references to any
// important functions, classes, or definitions in that file.
type RepoMap struct {
    Files []FileMetadata
}

type FileMetadata struct {
    Path        string
    PackageName string
    Imports     []string
    Symbols     []SymbolInfo // e.g., public functions, structs, etc.
}

type SymbolInfo struct {
    Name        string
    Kind        string // func, struct, interface, etc.
    StartLine   int
    EndLine     int
}
```

The **RepoMap** can be used at a coarse level to see which files and definitions might be relevant before diving into actual code content.

### 2. Index and Chunk Store

For large files, it’s helpful to **chunk** them into sections and store each chunk in a text index for fast retrieval. You can do this using:
- A simple full‐text index (e.g., Bleve, searching on code tokens).
- A semantic‐vector approach (using embeddings).

```go
type CodeChunk struct {
    FilePath string
    StartLine int
    EndLine   int
    Content   string
}

type CodeIndex interface {
    // AddChunk indexes a single chunk for later retrieval
    AddChunk(chunk CodeChunk) error

    // Search takes a query (which might be file-based, text-based, or both)
    // and returns a ranked list of relevant CodeChunks.
    Search(query string, limit int) ([]CodeChunk, error)
}
```

### 3. Retrieval Logic

The retrieval logic uses the **RepoMap** plus the **CodeIndex** to respond to queries. For example:

```go
func RetrieveContext(query string, repoMap *RepoMap, idx CodeIndex, limit int) []CodeChunk {
    // 1. Possibly parse the query if it references specific files or symbols.
    // 2. Use the index to look up relevant code (by file path or embeddings).
    // 3. Return the top `limit` chunks in descending order of relevance.
    chunks, _ := idx.Search(query, limit)
    return chunks
}
```

### 4. Activity Log / Fix Attempts

We keep an **activity log** so the LLM can see where it might be stuck or repeating itself. This might store each “fix attempt,” the relevant code context, the LLM’s proposed code changes, and the success or failure results.

```go
type FixAttempt struct {
    ID          string
    Timestamp   time.Time
    Query       string
    ProposedFix string
    Outcome     string // e.g. "success", "compilation error", "test failure"
    ErrorLog    string // logs from the build or test
}

type ActivityLog interface {
    RecordAttempt(attempt FixAttempt) error
    GetAttemptsByQuery(query string) ([]FixAttempt, error)
    // Possibly other helpers: get last attempt, etc.
}
```

This allows the LLM (or the controlling application) to see how many times a certain fix has been tried and which errors occurred.

### 5. Session / Task Management

We want the system to be idempotent. That means if the LLM asks the same question about “function X,” we don’t reintroduce brand‐new code or contradictory changes. One way is to maintain a “session” object that stores the relevant metadata (which code has been changed, which attempts have been made) under a session or task ID:

```go
type SessionState struct {
    SessionID   string
    StartTime   time.Time
    FilesChanged []string
    Attempts     []FixAttempt
}

// The SessionManager can create or retrieve an existing session by ID.
type SessionManager interface {
    CreateSession() *SessionState
    GetSession(sessionID string) (*SessionState, error)
    UpdateSession(state *SessionState) error
}
```

When the LLM tries to fix or modify a file, the controlling logic (or your orchestrator) updates this session state with the new changes and logs them. If the same fix is requested again, the session manager sees there’s already an attempt and either returns the previous code or records that it’s repeating itself.

---

## Putting It All Together

1. **Initialization**  
   - You scan the entire repo, build a **RepoMap**, chunk each file into `CodeChunk`s, and add them to the **CodeIndex**.  
   - You set up an **ActivityLog** (could be a simple local database, or logs on disk, or remote).  
   - You instantiate a **SessionManager** to track sessions.

2. **When the LLM (or a user) requests context**  
   - You parse the request (which might reference file paths or contain a textual query).  
   - Call `RetrieveContext(...)` to get the relevant code.  
   - If the system sees that it doesn’t have enough context (maybe the chunk coverage is low or the user requested more detail), it replies with something like “Insufficient context – which files or symbols are you interested in?” or includes the chunks it does have.  
   - The LLM can then refine its query or ask for more details.

3. **When the LLM proposes a fix**  
   - You record a **FixAttempt** in the **ActivityLog**, including the proposed changes.  
   - Optionally run a build or test; if it fails, mark the attempt as failed.  
   - Keep track of each fix attempt in the current session so you don’t accidentally revert or re‐apply the same changes in a loop.

4. **Avoiding Duplicate / Hallucinated Code**  
   - The retrieval logic always refers to the **RepoMap** and **CodeIndex** to check if a feature or function signature already exists.  
   - If the LLM tries to create a duplicate function, you can detect it by name or signature collisions in `RepoMap` or by searching the code index for near‐identical content.  
   - The “documented specification” can also be stored in the **Index** so the LLM can see if the feature is already implemented or explicitly out of scope.

5. **Ensuring Idempotency**  
   - Each session has a unique ID, and the system persists state about code changes. If the same fix is re‐requested, the manager can see that the code is already up to date and respond accordingly.

---

## Example: Minimal “contextstore” API

Below is a skeleton of how it might look in code. This is just a sketch, not a fully working library.

```go
package contextstore

import (
    "time"
)

// 1. The RepoMap + Index structures ----------------------------------

type SymbolInfo struct {
    Name      string
    Kind      string
    StartLine int
    EndLine   int
}

type FileMetadata struct {
    Path        string
    PackageName string
    Imports     []string
    Symbols     []SymbolInfo
}

type RepoMap struct {
    Files []FileMetadata
}

type CodeChunk struct {
    FilePath  string
    StartLine int
    EndLine   int
    Content   string
}

type CodeIndex interface {
    AddChunk(chunk CodeChunk) error
    Search(query string, limit int) ([]CodeChunk, error)
}

// 2. Retrieval -------------------------------------------------------

func RetrieveContext(query string, repoMap *RepoMap, idx CodeIndex, limit int) ([]CodeChunk, error) {
    // Heuristic: parse query for file references or symbol names (if needed).
    // Then use the index to search relevant text or code blocks.
    chunks, err := idx.Search(query, limit)
    if err != nil {
        return nil, err
    }
    return chunks, nil
}

// 3. Activity logging ------------------------------------------------

type FixAttempt struct {
    ID          string
    Timestamp   time.Time
    Query       string
    ProposedFix string
    Outcome     string
    ErrorLog    string
}

type ActivityLog interface {
    RecordAttempt(attempt FixAttempt) error
    GetAttemptsByQuery(query string) ([]FixAttempt, error)
}

// 4. Session management ---------------------------------------------

type SessionState struct {
    SessionID    string
    StartTime    time.Time
    FilesChanged []string
    Attempts     []FixAttempt
}

type SessionManager interface {
    CreateSession() (*SessionState, error)
    GetSession(sessionID string) (*SessionState, error)
    UpdateSession(state *SessionState) error
}
```

Your actual implementations might rely on:
- **SQLite** or some other local DB to store logs, sessions, and code chunks.  
- A **search library** or embedding model for the index (e.g., using an external service or a local vector store).  
- Additional error handling, concurrency controls, and watchers to keep the code index up to date if the codebase changes.

---

## Key Benefits & How This Addresses the Goals

1. **Enough context for the LLM**  
   By storing the codebase in chunks and indexing them, the LLM can retrieve precisely the relevant lines of code for a feature or fix.  

2. **Progress tracking and idempotency**  
   The combination of a **SessionManager** plus an **ActivityLog** ensures we record each fix attempt, preventing repeated loops for the same fix and letting the LLM see prior errors.

3. **Asking for more info**  
   If the LLM sees that the returned code snippets are incomplete, it can query again or request more files by reference. The system is designed to handle multiple retrieval queries in one session.

4. **Building according to specification**  
   You can index your specification or docs as well, letting the LLM compare code changes to the official spec. If a new feature is out of scope, the system can flag it or remind the LLM.

5. **Preventing hallucinations and duplicate code**  
   The index and activity log help detect if a function or block is about to be re‐implemented. Searching for an identical or near‐identical snippet before creation can catch duplicates or illusions.

6. **Log of failed fix attempts**  
   The `ActivityLog` and `FixAttempt` structures let you store each error’s cause (compilation, test failure, etc.), so the LLM can incorporate that context before trying again.

---

### Final Notes

- In practice, you’ll likely integrate this **contextstore** package with a higher‐level **orchestrator** that processes LLM messages, calls `RetrieveContext`, and then logs attempts.  
- Make sure your indexing approach (full‐text, embeddings, or both) is robust enough to handle large codebases.  
- Continuously update the index as files change so the LLM sees the latest versions.  
- This design can be extended with concurrency, caching, incremental index updates, or specialized chunk‐splitting logic for certain file types.

By following this design, you’ll have a clean, modular Go package that solves the primary challenges of (1) retrieving relevant code context, (2) tracking fix attempts, (3) avoiding duplication and hallucination, and (4) letting the LLM ask for more information as needed.