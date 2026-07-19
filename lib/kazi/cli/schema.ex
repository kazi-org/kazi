defmodule Kazi.CLI.Schema do
  @moduledoc """
  The versioned result schemas for kazi's `--json` output, as data (T16.1,
  ADR-0024 decision 2).

  `kazi schema [<command>]` emits these so any agent can introspect the shape of
  the `--json` result it parses at runtime — no external docs. Each schema mirrors
  the committed contract under `docs/schemas/` (`run-result.md`, `status.md`) and
  carries the same `schema_version` the result objects do (one number an
  orchestrator pins; a breaking change bumps it). The descriptors are intentionally
  flat — `{field, type, description}` rows plus an `example` object — the same
  field-table shape the docs use, so the doc and the emitted schema stay legible
  side by side.

  T27.4/T27.9 (ADR-0032): the schemas are keyed by the verbs `apply`/`plan` (was
  `run`/`propose`). The deprecated `run`/`propose` schema aliases were REMOVED in
  v0.6.0 (T27.9), so `kazi schema run` / `kazi schema propose` no longer resolve;
  `apply`/`plan`/`status`/`bus` are the valid schema keys (`bus` is the T55.1 /
  ADR-0072 digest envelope shared by `bus read|peek|watch --json` and the
  `kazi_bus_read`/`kazi_bus_watch` MCP tools).
  """

  # The contract version, shared with `Kazi.CLI`'s `@run_schema_version`. Kept in
  # lockstep: a breaking change to any `--json` result bumps both. Version 2
  # (ADR-0032, T27.3): the result contract's command key was renamed `run` ->
  # `apply` and `propose` -> `plan`; the deprecated `run`/`propose` aliases were
  # removed in v0.6.0 (T27.9).
  @schema_version 2

  # The result schemas, keyed by the command whose `--json` output they describe
  # (ADR-0032 verbs). `apply` (the convergence result, docs/schemas/run-result.md),
  # `plan` (the authoring/draft result), and `status` are the documented contracts;
  # the order is the order `all/0` emits. The deprecated `run`/`propose` aliases
  # were removed in v0.6.0 (T27.9) and are no longer valid keys.
  @schemas %{
    "apply" => %{
      schema_version: @schema_version,
      command: "apply",
      title: "kazi apply --json result",
      description:
        "The single, versioned JSON object `kazi apply --json` emits on termination — " <>
          "the convergence loop's own terminal result the orchestrator branches on. " <>
          "`apply` takes a goal-file path OR an APPROVED proposal's `prop-...` ref " <>
          "(T39.2, ADR-0049) — the ref `plan --json` mints and `approve --json` flips — " <>
          "loaded from the read-model, so no goal-file reconstruction is needed; the " <>
          "result object is identical either way.",
      fields: [
        %{name: "schema_version", type: "integer", description: "The contract version."},
        %{name: "goal_id", type: "string", description: "The goal's id."},
        %{
          name: "status",
          type: "string",
          description:
            "Terminal status, one of converged / stuck / over_budget / error. The primary branch."
        },
        %{
          name: "predicates",
          type: "array<object>",
          description:
            "The predicate vector: one {id, verdict} per predicate, sorted by id. " <>
              "verdict is pass / fail / error / unknown. ADR-0041 adds four OPTIONAL, " <>
              "additive fields per predicate, present only on a graded result: score " <>
              "(float), prior_score (float), direction (higher_better/lower_better), and " <>
              "evidence (array of LSP-Diagnostic-shaped items: {file,line,col,rule,level," <>
              "message,expected,got}). A boolean predicate carries none of them."
        },
        %{name: "iterations", type: "integer", description: "The loop's observation count."},
        %{
          name: "budget_spent",
          type: "object",
          description:
            "{iterations: integer, exceeded: string|null, tokens: integer}. exceeded names " <>
              "the budget dimension only when status is over_budget. tokens is the single " <>
              "rolled-up token total (ADR-0046 back-compat); the cached-vs-fresh split lives " <>
              "in the additive usage envelope below."
        },
        %{
          name: "usage",
          type: "object",
          description:
            "ADR-0046 economy envelope: OPTIONAL, ADDITIVE. Present only when the harness " <>
              "reported usage. Fields (each optional, omitted when unreported — absent is " <>
              "NOT zero): input_tokens, cached_input_tokens, cache_write_tokens, " <>
              "output_tokens, reasoning_tokens (integers), cost_usd (float). cost_usd is the " <>
              "harness's reported figure when given, else derived from the tokens via a single " <>
              "dated price map (T34.5) and OMITTED for an unpriced model — never guessed. " <>
              "Additive, so schema_version stays 2 (same rule as the ADR-0041 predicate envelope)."
        },
        %{
          name: "economy",
          type: "object",
          description:
            "T34.6/ADR-0046 run-end economy KPIs, DERIVED from the per-iteration envelopes. " <>
              "Always carries status, stuck (boolean), iterations; every DERIVED KPI is " <>
              "OMITTED when unavailable (absent is NOT zero): converged_predicates, " <>
              "iterations_to_convergence, tokens (the run-aggregate token total, T34.8), " <>
              "cost_usd, wall_clock_s, cost_per_converged_predicate, " <>
              "wall_clock_per_converged_predicate, fresh_input_tokens_avoided, " <>
              "rediscovery_tool_calls_avoided, plus the optional harness/model/context_tier " <>
              "breakdown labels. Additive, so schema_version stays 2."
        },
        %{
          name: "next_action",
          type: "string",
          description: "Orchestration hint: done / investigate / raise_budget. Not a kazi action."
        },
        %{
          name: "reason",
          type: "string|null",
          description: "The stop reason (the exceeded budget dimension or stuck), or null."
        },
        %{
          name: "release_ref",
          type: "string|null",
          description: "The release tag of the artifact deployed this run, or null."
        },
        %{
          name: "error",
          type: "string",
          description: "Present only when status is error: a pre-loop failure message."
        },
        %{
          name: "enforcement",
          type: "object",
          description:
            "T32.4/ADR-0042 anti-gaming guarantees that were ACTIVE for the run: " <>
              "{active: boolean, guarantees: array<string>, gaming_events: array<object>}. " <>
              "guarantees is the ACTUAL active set (e.g. clean_tree, separate_process, " <>
              "read_only_lease, fail_on_skip, ratchet_guards) — clean_tree is omitted when " <>
              "isolation degraded, so a partial guarantee is visible, never assumed. Each " <>
              "gaming_event is {type, path, iteration} (e.g. a flagged read_only_write). " <>
              "active is false when enforcement was off."
        }
      ],
      example: %{
        "schema_version" => @schema_version,
        "goal_id" => "cli-e2e",
        "status" => "converged",
        "predicates" => [
          %{"id" => "code", "verdict" => "pass"},
          %{"id" => "live", "verdict" => "pass"}
        ],
        "iterations" => 4,
        "budget_spent" => %{"iterations" => 4, "exceeded" => nil, "tokens" => 21_900},
        "usage" => %{
          "input_tokens" => 1500,
          "cached_input_tokens" => 18_000,
          "cache_write_tokens" => 0,
          "output_tokens" => 2400,
          "cost_usd" => 0.0123
        },
        "economy" => %{
          "status" => "converged",
          "stuck" => false,
          "iterations" => 4,
          "converged_predicates" => 2,
          "iterations_to_convergence" => 4,
          "tokens" => 21_900,
          "cost_usd" => 0.0123,
          "cost_per_converged_predicate" => 0.00615,
          "wall_clock_s" => 88.0,
          "wall_clock_per_converged_predicate" => 44.0,
          "fresh_input_tokens_avoided" => 18_000,
          "rediscovery_tool_calls_avoided" => 12
        },
        "next_action" => "done",
        "reason" => nil,
        "release_ref" => "v2026.06.23-abc1234",
        "enforcement" => %{
          "active" => true,
          "guarantees" => ["clean_tree", "fail_on_skip", "ratchet_guards", "separate_process"],
          "gaming_events" => []
        }
      }
    },
    "plan" => %{
      schema_version: @schema_version,
      command: "plan",
      title: "kazi plan --json result",
      description:
        "The single, versioned JSON object `kazi plan --json` emits — the drafted " <>
          "goal of acceptance predicates an orchestrator approves then applies.",
      fields: [
        %{name: "schema_version", type: "integer", description: "The contract version."},
        %{
          name: "goal_id",
          type: "string",
          description:
            "The drafted goal's id. Caller-drafts honors a payload-supplied \"goal_id\" " <>
              "verbatim (T39.1, ADR-0049); absent, it is derived from \"id\"/\"name\" or the idea."
        },
        %{
          name: "proposal_ref",
          type: "string",
          description:
            "The proposal handle (`prop-…`) used to approve/reject/status the draft — " <>
              "and to run it directly via `kazi apply <proposal-ref>` once approved " <>
              "(T39.2, ADR-0049)."
        },
        %{
          name: "status",
          type: "string",
          description: "The proposal's lifecycle state — proposed at draft time."
        },
        %{
          name: "idea",
          type: "string",
          description:
            "The prose idea the goal was drafted from. Caller-drafts honors a " <>
              "payload-supplied \"idea\" (T39.1, ADR-0049); absent, the positional idea " <>
              "or the generated placeholder stands."
        },
        %{
          name: "predicates",
          type: "array<object>",
          description:
            "The drafted predicates: {id, provider, description, acceptance, guard, config}."
        },
        %{
          name: "rationale",
          type: "string|null",
          description: "The drafting rationale recorded in the goal metadata, or null."
        },
        %{
          name: "clarify",
          type: "array<object>",
          description:
            "Open clarifying questions ({id, prompt, recommended}) for gaps still unguarded; " <>
              "empty when the draft is complete."
        }
      ],
      example: %{
        "schema_version" => @schema_version,
        "goal_id" => "ship-healthz",
        "proposal_ref" => "prop-ship-healthz-abc1234",
        "status" => "proposed",
        "idea" => "ship a healthz endpoint",
        "predicates" => [
          %{
            "id" => "code",
            "provider" => "test_runner",
            "description" => "the endpoint test passes",
            "acceptance" => true,
            "guard" => false,
            "config" => %{"cmd" => "sh", "args" => ["-c", "true"]}
          }
        ],
        "rationale" => "a live endpoint must answer 200",
        "clarify" => []
      }
    },
    "bus" => %{
      schema_version: @schema_version,
      command: "bus",
      title: "kazi bus read|peek|watch --json result (the digest envelope)",
      description:
        "The versioned JSON object `kazi bus read|peek|watch --json` emits (T55.1, " <>
          "ADR-0072) -- and the shape the `kazi_bus_read`/`kazi_bus_watch` MCP tools " <>
          "return. The DIGEST is the default machine shape: verbatim lines only for " <>
          "directed (kind msg) and sev interrupt messages, one-line stubs for bodies " <>
          "over the 1024-byte render threshold (ALL kinds, including directed/interrupt), " <>
          "exact count lines per {kind, topic} for everything else, bounded to 40 lines " <>
          "regardless of backlog size. `--full` (CLI) / `full: true` (MCP) is the " <>
          "documented escape: it replaces `digest` with `messages`, every pending " <>
          "message unabridged. Every message and digest line carries the message's " <>
          "JetStream stream sequence as its public `id`.",
      fields: [
        %{name: "schema_version", type: "integer", description: "The contract version."},
        %{name: "ok", type: "boolean", description: "true on a successful read."},
        %{
          name: "digest",
          type: "object",
          description:
            "Default shape (absent under --full): {total: integer (exact message count), " <>
              "lines: array<object>} with at most 40 lines. Each line has a `type`: " <>
              "\"verbatim\" ({type, id, kind, topic, sev, session, machine, ts, bytes, " <>
              "text} -- directed/interrupt bodies within the 1024-byte threshold), " <>
              "\"stub\" (same fields WITHOUT text -- any body over the threshold; the " <>
              "body stays in the stream, addressable by id), \"count\" ({type, kind, " <>
              "topic, count, first_id, last_id} -- everything else, exact counts, " <>
              "most-frequent first), or \"overflow\" (at most one, always last: {type, " <>
              "count, first_id, last_id} folding the tail past the 40-line bound, " <>
              "exact counts preserved)."
        },
        %{
          name: "messages",
          type: "array<object>",
          description:
            "--full / full: true only (replaces `digest`): every pending message " <>
              "unabridged -- {id, scope, kind, topic, text, session, machine, ts, sev}. " <>
              "`id` is the message's JetStream stream sequence."
        },
        %{
          name: "timed_out",
          type: "boolean",
          description:
            "kazi_bus_watch (MCP) only: true when the watch expired with no traffic -- " <>
              "an expected outcome to branch on, never an error. The CLI signals the " <>
              "same via exit code 3."
        }
      ],
      example: %{
        "schema_version" => @schema_version,
        "ok" => true,
        "digest" => %{
          "total" => 202,
          "lines" => [
            %{
              "type" => "verbatim",
              "id" => 412,
              "kind" => "msg",
              "topic" => "session-a",
              "sev" => "info",
              "session" => "session-b",
              "machine" => "host1",
              "ts" => "2026-07-16T12:00:00Z",
              "bytes" => 14,
              "text" => "review is done"
            },
            %{
              "type" => "stub",
              "id" => 413,
              "kind" => "note",
              "topic" => "design",
              "sev" => "info",
              "session" => "session-c",
              "machine" => "host1",
              "ts" => "2026-07-16T12:01:00Z",
              "bytes" => 61_440
            },
            %{
              "type" => "count",
              "kind" => "fact",
              "topic" => "ci",
              "count" => 200,
              "first_id" => 210,
              "last_id" => 411
            }
          ]
        }
      }
    },
    "status" => %{
      schema_version: @schema_version,
      command: "status",
      title: "kazi status --json result",
      description:
        "The single, versioned JSON object `kazi status <ref> --json` emits — a pure " <>
          "read of the read-model reporting a run's or proposal's current state.",
      fields: [
        %{name: "schema_version", type: "integer", description: "The contract version."},
        %{
          name: "kind",
          type: "string",
          description: "run or proposal — which surface the ref resolved to."
        },
        %{name: "ref", type: "string", description: "The goal/proposal ref reported on."},
        %{
          name: "status",
          type: "string",
          description:
            "For a run: converged / in_progress. For a proposal: proposed / approved / rejected."
        },
        %{
          name: "converged",
          type: "boolean",
          description: "run only: whether the latest recorded iteration converged."
        },
        %{
          name: "iteration",
          type: "integer",
          description: "run only: the latest recorded 0-based iteration index."
        },
        %{
          name: "predicates",
          type: "array<object>",
          description:
            "run only: the predicate vector ({id, verdict}, sorted by id). ADR-0041 adds " <>
              "optional, additive per-predicate fields on a graded result: score, " <>
              "prior_score, direction, and evidence (LSP-Diagnostic-shaped items)."
        },
        %{
          name: "release_ref",
          type: "string|null",
          description: "run only: the release ref recorded on the latest iteration, or null."
        },
        %{
          name: "observed_at",
          type: "string",
          description: "run only: ISO-8601 timestamp the latest iteration was evaluated."
        },
        %{name: "goal_id", type: "string", description: "proposal only: the drafted goal's id."},
        %{
          name: "idea",
          type: "string",
          description: "proposal only: the prose idea the proposal was drafted from."
        }
      ],
      example: %{
        "schema_version" => @schema_version,
        "kind" => "run",
        "ref" => "cli-e2e",
        "status" => "in_progress",
        "converged" => false,
        "iteration" => 3,
        "predicates" => [
          %{"id" => "code", "verdict" => "pass"},
          %{"id" => "live", "verdict" => "fail"}
        ],
        "release_ref" => "v2026.06.24-abc1234",
        "observed_at" => "2026-06-24T03:25:31.118115Z"
      }
    }
  }

  # The verbs with a documented result schema, in emit order. `all/0` keys by
  # these. The deprecated `run`/`propose` schema aliases were removed in v0.6.0
  # (T27.9), so these are the only valid schema keys.
  @ordered_commands ["apply", "plan", "status", "bus"]

  @doc "The shared `--json` contract version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "The commands that have a documented result schema, in emit order."
  @spec commands() :: [String.t()]
  def commands, do: @ordered_commands

  @doc """
  Every result schema, keyed by the PRIMARY command, plus the shared
  `schema_version` — what `kazi schema` (no command) emits.
  """
  @spec all() :: map()
  def all do
    %{
      schema_version: @schema_version,
      schemas: Map.new(@ordered_commands, fn cmd -> {cmd, @schemas[cmd]} end)
    }
  end

  @doc """
  Fetch one command's result schema. Returns `{:ok, schema}` or `:error` for a
  command with no documented `--json` result (including the removed `run`/`propose`
  aliases, T27.9).
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(command), do: Map.fetch(@schemas, command)
end
