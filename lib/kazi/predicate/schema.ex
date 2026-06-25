defmodule Kazi.Predicate.Schema do
  @moduledoc """
  Self-describing config schemas for predicate-provider kinds (T32.1, ADR-0040
  decision 6).

  `kazi schema <provider-kind>` emits one of these so any agent can introspect the
  config keys a predicate of that kind accepts — no external docs. Today this
  covers `custom_script` (the generic command-runner whose verdict/evidence keys
  are config, not code); other kinds can be added the same way.

  The descriptor is intentionally flat — a `keys` list of
  `{name, type, required, description}` rows plus an `example` config object — the
  same field-table shape the result schemas (`Kazi.CLI.Schema`) and the goal-file
  docs use, so the doc and the emitted schema stay legible side by side.
  """

  @custom_script %{
    kind: "custom_script",
    title: "custom_script predicate config",
    description:
      "The generic command-runner (ADR-0040): run a declared command in the workspace and " <>
        "map its result to a verdict. The sanctioned extension point — a new verification " <>
        "kind is config, not a kazi release.",
    keys: [
      %{
        name: "cmd",
        type: "string",
        required: true,
        description: "The executable to run (ONE executable, not a command line; use args)."
      },
      %{
        name: "args",
        type: "array<string>",
        required: false,
        description: "Argument list passed to cmd. Default []."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment as a {name = value} table or {name, value} pairs."
      },
      %{
        name: "verdict",
        type: "string",
        required: false,
        description:
          "How the result maps to a status: \"exit_zero\" (default; exit 0 -> pass), " <>
            "\"exit_code\" (map specific codes), or \"json\" (gate on parsed stdout)."
      },
      %{
        name: "pass_codes",
        type: "array<integer>",
        required: false,
        description:
          "verdict=exit_code: exit codes that count as pass. Required for that verdict."
      },
      %{
        name: "fail_codes",
        type: "array<integer>",
        required: false,
        description:
          "verdict=exit_code: exit codes that count as fail. A code in neither list is fail."
      },
      %{
        name: "path",
        type: "string",
        required: false,
        description:
          "verdict=json: a JSONPath subset over stdout ($, .key, [index]) to the value to " <>
            "compare. A list value compares its length. Required for that verdict."
      },
      %{
        name: "pass_when",
        type: "string",
        required: false,
        description:
          "verdict=json: the comparison the extracted number must satisfy to pass, " <>
            "\"<op> <number>\" with op one of == != < <= > >=. Required for that verdict."
      },
      %{
        name: "error_codes",
        type: "array<integer>",
        required: false,
        description:
          "Exit codes that mean the checker could not run -> :error (infra, not failing work), " <>
            "checked before the verdict."
      },
      %{
        name: "evidence_format",
        type: "string",
        required: false,
        description:
          "Shape evidence from a recognised envelope on stdout: \"sarif\", \"junit\", " <>
            "\"json\", or \"raw\" (default). Never changes the verdict."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description:
          "Kill the command after this many ms and map it to :error. Default: no timeout."
      }
    ],
    example: %{
      "id" => "no-high-severity-findings",
      "provider" => "custom_script",
      "cmd" => "semgrep",
      "args" => ["--sarif", "--config", "auto", "."],
      "verdict" => "json",
      "evidence_format" => "sarif",
      "path" => "$.runs[0].results",
      "pass_when" => "== 0"
    }
  }

  @schemas %{"custom_script" => @custom_script}

  @doc "The provider kinds with a documented config schema, sorted."
  @spec kinds() :: [String.t()]
  def kinds, do: @schemas |> Map.keys() |> Enum.sort()

  @doc """
  Fetch one provider kind's config schema. Returns `{:ok, schema}` or `:error`
  for a kind with no documented schema.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(kind), do: Map.fetch(@schemas, kind)
end
