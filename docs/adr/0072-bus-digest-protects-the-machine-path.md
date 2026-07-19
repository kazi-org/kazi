# ADR 0072: The bus digest protects the machine path — context cost is bounded at render, not at post

## Status
Accepted

## Date
2026-07-16

## Refines / supersedes

Supersedes the **enforcement mechanism** of ADR-0067 decision point 5 — the
"hard per-message size cap (~1 KB) forces one-line discipline at the producer"
clause — and **reaffirms point 5's goal verbatim**: "token cost must be
decoupled from message volume *by design*, not by client discipline", and
"only a server can aggregate before the tokens are spent". The goal was right.
The mechanism was the wrong place to stand, and it did not survive contact with
a real need.

This ADR does **not** revert the limits raised by the document-sized-messages
change (64 KiB text / 128 KiB stream / 30-day retention). It keeps them and
moves the enforcement to where it works.

## Context

ADR-0067 point 5 promised: "`kazi bus read` returns a *digest*, not a
transcript... Reading a thousand-message backlog costs the same context as
reading forty lines. This is the reason a daemon (rather than a shared file) is
load-bearing: only a server can aggregate before the tokens are spent."

**The shipped digest does the opposite.** `Kazi.Bus.Digest.summarize/1` is a
pure function in the CLI, reached only through `print_read_digest/1`, which is
called only from the human-readable branch of `emit/3`:

```elixir
emit(json?(opts), %{"ok" => true, "messages" => messages}, fn ->
  print_read_digest(messages)   # TTY branch ONLY
end)
```

With `--json` the CLI emits `messages` verbatim, and the `kazi_bus_*` MCP tools
mirror that JSON path. So the digest protects the reader who has a scrollback
and pays no tokens, and abandons the reader ADR-0067 itself identifies as the
scarce resource: "The readers are LLM sessions. Every message a session reads
occupies context-window tokens." Every machine-readable path — `--json`, MCP,
and the hook recipe point 6 documents (`kazi bus read --json`) — receives the
full transcript. The one surface that must be cheap is the one surface that
isn't.

The caps that had been backstopping this were then deliberately raised. The
document-sized-messages change lifted the text cap from 1 KiB to 64 KiB, the
stream limit to 128 KiB, and retention from 24h to 30 days, alongside a genuine
provisioning fix (reconciling config rather than create-only, which had pinned
old stores to a TTL-less presence bucket so closed sessions looked active
forever). **That change was correct on its own terms.** It was made because
"four gaps kept the session bus from serving as a team's primary channel" — a
real, observed need to carry more than a single line. Its mistake was not
raising the cap; it was that the cap was, unknowingly, the *only* thing bounding
context cost, because the digest had never been wired to the path agents use.

The result is measurable on the live bus today: a single `kazi bus peek --json`
returns the entire backlog verbatim, including two filler messages of roughly
10–20 KB each. A session that checks the bus once can pay more context for the
check than for the work.

E51's own risk register predicted this precisely — **R-E51-4: "Digest logic
under-delivers and bus reads flood session context"** — and listed three
mitigations. All three are gone or unstarted: the hard 1 KB cap (raised 64×),
T51.4 "a dedicated task, not an afterthought" (open), and T51.6's token-cost
measurement (open, and blocked on T51.4). The risk did not slip through a gap in
the plan; it slipped through every mitigation the plan named.

## Decision

**The digest is a property of reading, not of writing. It is enforced on every
machine-readable path, and it bounds context cost independently of what the bus
stores.**

1. **The digest is the default on every machine-readable surface** — `--json`
   and every `kazi_bus_*` MCP tool — exactly as it already is on the TTY.
   `--full` (CLI) / `full: true` (MCP) is the explicit, documented escape for
   debugging. The asymmetry between the human and machine paths is the bug; the
   machine path is the one that needed it. The digest JSON joins the ADR-0023
   versioned result contract — it carries a `schema_version` and its shape is
   introspectable via `kazi schema` — which the bare `{ok, messages}` envelope
   the bus verbs emit today never did; the shape change this ADR makes is the
   right moment to bring them under the contract every other agent-facing kazi
   surface already honours.

2. **Stored size is decoupled from context cost.** The bus MAY carry documents
   — the 64 KiB text cap, 128 KiB stream limit, and 30-day retention stand,
   because the need that produced them is real. But **the digest never renders
   a body over a render threshold verbatim**: an oversized message collapses to
   a one-line stub carrying its id, kind, topic, provenance, and size. Volume
   *and* size are bounded at render.

3. **`kazi bus get <id>` is the deliberate pull.** Full text is addressable and
   fetched on purpose, by a session that has decided it is worth the context.
   Reading a document becomes a choice with a visible cost, rather than an
   ambush inside a routine check. The id is the message's JetStream stream
   sequence — already tracked internally for cross-consumer deduplication and
   today stripped from every message before it is returned; it becomes the
   public identifier, carried on every digest line and stub, so an id printed
   in a digest is always dereferenceable.

4. **Discipline moves from the producer to the render.** This is the actual
   supersede. Point 5 asked producers to be terse and enforced it with a cap;
   producers cannot know their readers' budgets, and the first real need for a
   longer message removed the cap and took the guarantee with it. A render-time
   bound cannot be lifted by a feature commit, and it holds no matter how
   undisciplined the traffic is.

5. **Assembly moves server-side into the daemon.** The client sends `read` over
   the control socket; the daemon pulls the consumer, aggregates last-value
   facts per topic, collapses repeated presence/intent, and enforces
   verbatim-only-for-directed-or-interrupt. This is point 5's own load-bearing
   argument — "only a server can aggregate before the tokens are spent" —
   finally honoured, and it is what makes the digest uniform across the CLI,
   the MCP tools, and the ADR-0076 hook rather than re-implemented three times.

6. **The digest has a stated, tested bound.** A digest is at most N lines
   regardless of backlog depth or message size, with exact counts preserved.
   The bound is an acceptance criterion, not an aspiration: point 5's "a
   thousand-message backlog costs the same as forty lines" becomes a test.

7. **Verbatim remains reserved** for directed messages (`kind: msg`) and
   `sev: interrupt`, per point 5 — subject to point 2's stub rule, which
   applies to every kind. An urgent message is rendered; an urgent 60 KB
   message is rendered as a stub with its id.

## Consequences

- The ADR-0076 hook becomes affordable. Push delivery is only safe once a read
  is bounded; these two ADRs are independently correct but jointly necessary,
  and the epic must not enable delivery to real sessions before the bound
  lands.
- The document-sized-messages capability survives with its cost contained: post
  the document, and the digest shows a stub until someone wants it.
- `bus get` gives the bus content addressing it has never had, which the board
  (ADR-0073) also needs to point at long-form artifacts.
- Digest logic in the daemon means a bus client is thin. A future non-CLI client
  gets the token economy for free.
- Sessions that today parse `.messages[]` from `bus read --json` will see stubs
  and digest lines instead. `--full` restores the old shape; this is a
  deliberate, breaking-by-design change to a surface whose current shape is the
  defect.

## Non-goals

- **Not a revert of the raised limits.** The bus keeps carrying documents. See
  point 2.
- **Not lossy storage.** The digest bounds *rendering*; the stream retains the
  full message for 30 days and `bus get` returns it intact.
- **Not summarization by model.** The digest is deterministic aggregation —
  counts, last-values, stubs. No LLM sits in the read path.
- **Not memory** (ADR-0067 point 8, unchanged). Events still age out; durable
  knowledge still routes through the ADR-0036 tiers.

## Alternatives rejected

- **Restore the 1 KB producer cap.** Re-breaks the real need that raised it,
  and puts the burden on the one party that cannot see the reader's budget. The
  cap already proved removable by a well-intentioned feature commit; a
  guarantee that a feature commit can silently void is not a guarantee.
- **Truncate every oversized body blindly at read.** Bounds cost but destroys
  addressability — the reader learns something big happened and has no way to
  read it. Point 3 costs one verb and keeps the content reachable.
- **Keep the digest client-side and just apply it to `--json` too.** The cheap
  fix, and it is genuinely most of the win — but it re-implements aggregation
  in every client, cannot collapse across sessions, and abandons point 5's
  server-side argument for no saved work. The epic sequences it first (T55.1)
  *and then* moves it into the daemon (T55.6) rather than choosing.
- **Let each session filter with `--since` / topic filters.** Client discipline
  under another name — the exact thing point 5 ruled out "by design".
