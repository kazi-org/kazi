# ADR 0014: Binary distribution via Burrito + Homebrew (supersedes escript-as-distribution)

## Status
Accepted

## Date
2026-06-22

## Context

kazi currently ships as a `mix escript.build` artifact (`./kazi`). An escript is NOT
a self-contained binary: it requires Erlang/OTP installed on the user's machine, and
it CANNOT bundle native NIFs — so the escript runs WITHOUT the SQLite read-model
(`ecto_sqlite3` is a NIF), silently degrading persistence (documented in the README).
This blocks a clean `brew install` story and means the most convenient distribution
form is also the least capable one.

We want: install with one command (`brew install kazi-org/tap/kazi`), no Erlang
prerequisite, and full functionality including the read-model.

## Decision

1. **Ship a true single-file native binary per platform with [Burrito](https://github.com/burrito-elixir/burrito).**
   Burrito wraps a `mix release` (which bundles ERTS and compiled NIFs) into one
   self-extracting executable per target. Targets: macOS `aarch64`/`x86_64` and Linux
   `x86_64`/`aarch64`. Because a release bundles the `ecto_sqlite3` NIF, the binary has
   the **full read-model** — fixing the escript limitation in the same move.

2. **`mix release` is the foundation; Burrito is the wrapper.** Add a `releases:` block
   for a `kazi` release exposing the CLI entrypoint; Burrito consumes that release.

3. **Build + publish in CI.** A tag-triggered GitHub Actions matrix builds the Burrito
   binaries on macOS and Ubuntu runners and uploads them (with checksums) to GitHub
   Releases. Versioning via release-please (Conventional Commits).

4. **Homebrew via a tap repo.** A `kazi-org/homebrew-tap` formula downloads the
   per-platform artifact + checksum from the GitHub Release, so `brew install
   kazi-org/tap/kazi` installs a working `kazi`.

5. **The escript remains a developer convenience, not the shipping artifact.** The
   README's primary install path becomes the binary; the escript note stays for
   contributors but is no longer the recommended distribution.

## Consequences

Positive: one-command install with no Erlang prerequisite; the distributed binary is
fully capable (read-model included); reproducible, checksummed release artifacts.

Negative: per-platform builds add CI complexity (a build matrix across OSes) and a
second repo (the Homebrew tap) to maintain. Burrito binaries are large (they embed
ERTS). The binary ships kazi only — it still requires the user's coding agent
(`claude`/Codex) on PATH at runtime, since kazi drives a harness by design (ADR-0001);
that runtime dependency is inherent and documented, not solved by packaging.
