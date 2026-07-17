defmodule Kazi.Context.StuckBundle do
  @moduledoc """
  The compact stuck bundle for escalation replay (T35.6, ADR-0045 §5).

  When `kazi apply` stops `:stuck` (the same non-empty failing set persisted across
  the stuck window, T1.5), the ADR-0035 model-ladder escalation re-dispatches the
  goal on a higher, pricier model rung. Handing that rung the lower rung's ENTIRE
  transcript re-pays for every token of failed work. This module assembles the
  *compact* alternative: only what the higher rung needs to make progress —

    * the failing predicates + their normalized failure,
    * the last changed files (the working-set digest),
    * budget-fitted snippets retrieved from the context store for the error
      signatures (empty when no store is configured), and
    * an overall byte bound so the bundle stays small.

  kazi PRODUCES the bundle (surfaced on the stuck result); the ADR-0035 escalation
  is skill-side (it reads the bundle and re-dispatches on the higher rung). This
  module wires no model switch — it is a pure, total projection, redacted on egress
  via `Kazi.Redaction` like every other thing kazi hands a harness.
  """

  alias Kazi.ContextStore.Snippet
  alias Kazi.Redaction

  # Default total byte budget for the bundle (ADR-0045 §9: stuck-escalation ≈ 12 000).
  @default_budget 12_000
  # Per-predicate failure text cap, so one noisy predicate cannot crowd out the rest.
  @per_failure_bytes 1_500
  # When fitting the LAST failing predicate to budget, shed the expendable
  # changed-files list until the failure text has at least this much room, rather
  # than blanking the failure to make room for file paths (issue #1075).
  @min_failure_room 200
  # Cap on the number of changed-file paths listed.
  @max_changed_files 50

  # (issue #769) Denied tool NAMES are a tiny, bounded set in practice (Write, Edit,
  # Bash, …); this is a sanity cap so a pathological harness cannot flood the bundle.
  @max_permission_denials 20

  @typedoc "The assembled bundle — a JSON-safe map (string keys)."
  @type t :: %{
          required(String.t()) => term()
        }

  @typedoc "The inputs the loop extracts from its stuck state."
  @type input :: %{
          optional(:failing) => [{term(), map()}],
          optional(:changed_files) => [String.t()],
          # (issue #769) Denied tool NAMES only — never a denial's `tool_input`.
          optional(:permission_denials) => [String.t()],
          optional(:snippets) => [Snippet.t()]
        }

  @doc """
  Assembles a bounded, redacted bundle from the stuck-state `input`.

  `opts[:budget]` is the total byte ceiling (default #{@default_budget}). The
  returned map carries `"bytes"` — the byte size of the rendered bundle — which is
  always `<= budget`.

  ## Examples

      iex> b = Kazi.Context.StuckBundle.assemble(%{failing: [{:code, %{output: "boom"}}], changed_files: ["lib/a.ex"]})
      iex> b["failing_predicates"]
      [%{"id" => "code", "failure" => "boom"}]
      iex> b["changed_files"]
      ["lib/a.ex"]
  """
  @spec assemble(input(), keyword()) :: t()
  def assemble(input, opts \\ []) when is_map(input) and is_list(opts) do
    budget = Keyword.get(opts, :budget, @default_budget)

    failing =
      input
      |> Map.get(:failing, [])
      |> Enum.map(&failing_entry/1)

    changed =
      input
      |> Map.get(:changed_files, [])
      |> Enum.filter(&is_binary/1)
      |> Enum.take(@max_changed_files)
      |> Enum.map(&Redaction.redact/1)

    snippets =
      input
      |> Map.get(:snippets, [])
      |> Enum.map(&snippet_entry/1)

    bundle =
      %{
        "failing_predicates" => failing,
        "changed_files" => changed,
        "snippets" => snippets
      }
      |> put_permission_denials(input)
      |> fit_budget(budget)

    Map.put(bundle, "bytes", byte_size(render(bundle)))
  end

  # (issue #769) The names of tool calls the harness had DENIED. Present only when
  # there were any, so an unaffected bundle's shape is byte-for-byte unchanged.
  # Names only — a denial's `tool_input` holds the whole file a denied `Write`
  # meant to write, which would blow the budget and risk leaking secrets here.
  defp put_permission_denials(bundle, input) do
    case input |> Map.get(:permission_denials, []) |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] -> bundle
      names -> Map.put(bundle, "permission_denials", Enum.take(names, @max_permission_denials))
    end
  end

  @doc """
  Renders the bundle as a compact text block for the escalation prompt — the thing
  the higher rung receives INSTEAD of the full transcript.
  """
  @spec render(t()) :: String.t()
  def render(%{} = bundle) do
    [
      section("Failing predicates", failing_lines(bundle["failing_predicates"])),
      section("Last changed files", file_lines(bundle["changed_files"])),
      # (issue #769) Rendered so the ESCALATION prompt says why nothing changed —
      # a higher rung handed "no changed files" with no cause would just re-fail.
      section(
        "Denied tool calls (agent could not act)",
        denial_lines(bundle["permission_denials"])
      ),
      section("Relevant indexed evidence", snippet_lines(bundle["snippets"]))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # --- assembly helpers ------------------------------------------------------

  defp failing_entry({id, evidence}) when is_map(evidence) do
    %{
      "id" => to_string(id),
      "failure" => evidence |> failure_text() |> cap(@per_failure_bytes) |> Redaction.redact()
    }
  end

  defp failing_entry({id, other}) do
    %{
      "id" => to_string(id),
      "failure" => other |> inspect() |> cap(@per_failure_bytes) |> Redaction.redact()
    }
  end

  # The normalized failure text: the evidence's `:output` (the command/test output)
  # when present, else a compact inspect of the evidence map.
  defp failure_text(%{output: output}) when is_binary(output), do: output

  defp failure_text(evidence),
    do: inspect(evidence, limit: 20, printable_limit: @per_failure_bytes)

  defp snippet_entry(%Snippet{text: text, source: source}),
    do: %{"source" => source, "text" => Redaction.redact(text)}

  defp snippet_entry(%{} = m),
    do: %{
      "source" => Map.get(m, "source"),
      "text" => m |> Map.get("text", "") |> Redaction.redact()
    }

  # Trim sections (snippets first, then per-failure detail) until the rendered
  # bundle fits the byte budget — snippets are the most expendable (the failing
  # evidence + changed files are the irreducible signal).
  defp fit_budget(bundle, budget) do
    if byte_size(render(bundle)) <= budget do
      bundle
    else
      cond do
        bundle["snippets"] != [] ->
          fit_budget(Map.put(bundle, "snippets", drop_last(bundle["snippets"])), budget)

        length(bundle["failing_predicates"]) > 1 ->
          fit_budget(
            Map.put(bundle, "failing_predicates", drop_last(bundle["failing_predicates"])),
            budget
          )

        true ->
          fit_last_failure(bundle, budget)
      end
    end
  end

  # The single remaining failing predicate is still over budget. Its failure text
  # is the irreducible signal — the actual error the higher rung needs to make
  # progress — so it is SHRUNK, never blanked (issue #1075). The prior code
  # computed room as `budget - overhead` where `overhead` counted the (expendable)
  # changed-files list as fixed; when that list alone filled the budget, room
  # collapsed to 0 and `cap(failure, 0)` erased the failure to `""` — surfacing an
  # empty `"failure"` in the stuck report while keeping a file list nobody needed.
  # Fix: when the overhead crowds the failure below a usable floor, shed a
  # changed-file path (the expendable part) and retry, so the failure keeps its
  # room; only when nothing expendable remains does the failure absorb the
  # shortfall, and even then it keeps at least one byte (`max(room, 1)`) rather
  # than blanking.
  defp fit_last_failure(bundle, budget) do
    [f | rest] = bundle["failing_predicates"]

    overhead =
      byte_size(render(%{bundle | "failing_predicates" => [%{f | "failure" => ""} | rest]}))

    room = budget - overhead

    if room < @min_failure_room and bundle["changed_files"] != [] do
      fit_last_failure(
        Map.put(bundle, "changed_files", drop_last(bundle["changed_files"])),
        budget
      )
    else
      kept = cap(f["failure"], max(room, 1))
      %{bundle | "failing_predicates" => [%{f | "failure" => kept} | rest]}
    end
  end

  defp drop_last([]), do: []
  defp drop_last(list), do: Enum.drop(list, -1)

  defp cap(text, max) when byte_size(text) <= max, do: text
  defp cap(text, max), do: binary_part(text, 0, max) |> valid_prefix()

  defp valid_prefix(bin) do
    if String.valid?(bin), do: bin, else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # --- render helpers --------------------------------------------------------

  defp section(_title, ""), do: ""
  defp section(title, body), do: "## " <> title <> "\n" <> body

  defp failing_lines([]), do: ""

  defp failing_lines(entries),
    do: Enum.map_join(entries, "\n", fn e -> "- #{e["id"]}: #{e["failure"]}" end)

  defp file_lines([]), do: ""
  defp file_lines(files), do: Enum.map_join(files, "\n", &("- " <> &1))

  # (issue #769) Absent key (the overwhelmingly common case: nothing was denied) and
  # an empty list both render to no section at all.
  defp denial_lines(nil), do: ""
  defp denial_lines([]), do: ""

  defp denial_lines(names) do
    Enum.map_join(names, "\n", &("- " <> &1 <> " (denied)")) <>
      "\n\nThe harness exited 0 but every listed tool call was refused, so no edit " <>
      "could land. Set `[harness] permission_mode` in the goal-file."
  end

  defp snippet_lines([]), do: ""

  defp snippet_lines(snippets) do
    Enum.map_join(snippets, "\n\n", fn s ->
      case s["source"] do
        nil -> "```\n" <> s["text"] <> "\n```"
        src -> "### " <> src <> "\n```\n" <> s["text"] <> "\n```"
      end
    end)
  end
end
