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
  only `apply`/`plan`/`status` are valid schema keys.
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
          "the convergence loop's own terminal result the orchestrator branches on.",
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
              "verdict is pass / fail / error / unknown."
        },
        %{name: "iterations", type: "integer", description: "The loop's observation count."},
        %{
          name: "budget_spent",
          type: "object",
          description:
            "{iterations: integer, exceeded: string|null}. exceeded names the budget " <>
              "dimension only when status is over_budget."
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
        "budget_spent" => %{"iterations" => 4, "exceeded" => nil},
        "next_action" => "done",
        "reason" => nil,
        "release_ref" => "v2026.06.23-abc1234"
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
        %{name: "goal_id", type: "string", description: "The drafted goal's id."},
        %{
          name: "proposal_ref",
          type: "string",
          description: "The proposal handle (`prop-…`) used to approve/reject/status the draft."
        },
        %{
          name: "status",
          type: "string",
          description: "The proposal's lifecycle state — proposed at draft time."
        },
        %{name: "idea", type: "string", description: "The prose idea the goal was drafted from."},
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
          description: "run only: the predicate vector ({id, verdict}, sorted by id)."
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
  @ordered_commands ["apply", "plan", "status"]

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
