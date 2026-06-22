defmodule Kazi.Context.Pack do
  @moduledoc """
  A bounded, ranked orientation pack (T4.2, ADR-0010): the structured map-memory
  `Kazi.Context.orientation_pack/3` produces and `render/1` turns into the stable
  prompt prefix T4.3 prepends to `build_prompt/2`.

  A pack holds three ranked collections — impacted `files`, impacted `symbols`
  (with callers/callees), and the failing test's `test_sources` — plus the
  `token_budget` it was bounded to and the `origin` (`:graph` or `:repo_map`) it
  was built from. Entries arrive already ranked highest-first; `render/1` is a pure
  function of the struct, so equal packs render byte-identically (the determinism
  ADR-0010 requires for prompt-cache hits).

  ## Token budget

  Tokens are estimated without a tokenizer dependency as `ceil(chars / 4)` over the
  rendered text (`estimated_tokens/1`). `truncate_to_budget/2` drops the
  lowest-ranked entries — first extra symbols, then extra files, never the test
  sources or the leading impacted file — until the render fits, so the most
  relevant orientation survives the cut.
  """

  alias Kazi.Context.{FileRef, Symbol}

  @typedoc """
    * `:origin` — `:graph` or `:repo_map` (provenance).
    * `:files` / `:symbols` / `:test_sources` — ranked highest-first.
    * `:token_budget` — the ceiling the pack was truncated to fit.
  """
  @type t :: %__MODULE__{
          origin: :graph | :repo_map,
          files: [FileRef.t()],
          symbols: [Symbol.t()],
          test_sources: [FileRef.t()],
          token_budget: pos_integer() | nil
        }

  defstruct origin: :repo_map, files: [], symbols: [], test_sources: [], token_budget: nil

  # Average English/code chars-per-token; good enough to bound a prompt without
  # pulling a tokenizer dependency (ADR-0010: approximate by chars/4).
  @chars_per_token 4

  @doc """
  Estimated token count of the pack, as `ceil(rendered_chars / 4)`. Pure: a
  function of the rendered text only.
  """
  @spec estimated_tokens(t()) :: non_neg_integer()
  def estimated_tokens(%__MODULE__{} = pack) do
    chars = pack |> render() |> String.length()
    div(chars + @chars_per_token - 1, @chars_per_token)
  end

  @doc """
  Truncates the pack so `estimated_tokens/1 <= budget`, dropping the lowest-ranked
  entries first: surplus symbols, then surplus files. Test sources and the
  top-ranked impacted file are preserved (they are the irreducible orientation).
  Returns the (possibly identical) pack with its `:token_budget` recorded.

  Idempotent and deterministic: re-truncating a truncated pack to the same budget
  is a no-op.
  """
  @spec truncate_to_budget(t(), pos_integer()) :: t()
  def truncate_to_budget(%__MODULE__{} = pack, budget) when is_integer(budget) and budget > 0 do
    pack = %{pack | token_budget: budget}

    pack
    |> drop_until_fits(:symbols, budget)
    |> drop_until_fits(:files, budget)
  end

  # Drops entries from the tail of `field` one at a time until the pack fits the
  # budget or only the irreducible minimum (one entry) remains in that field.
  defp drop_until_fits(pack, field, budget) do
    cond do
      estimated_tokens(pack) <= budget ->
        pack

      length(Map.fetch!(pack, field)) <= keep_minimum(field) ->
        pack

      true ->
        trimmed = Map.update!(pack, field, &drop_last/1)
        drop_until_fits(trimmed, field, budget)
    end
  end

  # Files keep at least the single top-ranked impacted file as a last resort;
  # symbols may be dropped entirely.
  defp keep_minimum(:files), do: 1
  defp keep_minimum(:symbols), do: 0

  defp drop_last([]), do: []
  defp drop_last(list), do: Enum.drop(list, -1)

  @doc """
  Renders the pack to the deterministic orientation text prepended to the prompt
  (T4.3). Pure function of the struct: equal packs render to byte-identical
  strings, including a stable header so the prefix shape never depends on whether
  the source found anything.

  ## Examples

      iex> pack = %Kazi.Context.Pack{origin: :graph, files: [Kazi.Context.FileRef.new("lib/a.ex")]}
      iex> Kazi.Context.Pack.render(pack) =~ "lib/a.ex"
      true
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = pack) do
    [
      "# Orientation (#{pack.origin})",
      "",
      "kazi pre-computed where this work lives so you start oriented. " <>
        "This is structure, not history — verify against the source before editing.",
      render_section("## Impacted files", render_files(pack.files)),
      render_section("## Impacted symbols", render_symbols(pack.symbols)),
      render_section("## Failing test source", render_test_sources(pack.test_sources))
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
  end

  defp render_section(_heading, ""), do: nil
  defp render_section(heading, body), do: "\n" <> heading <> "\n" <> body

  defp render_files([]), do: ""

  defp render_files(files) do
    Enum.map_join(files, "\n", fn %FileRef{path: path} -> "- #{path}" end)
  end

  defp render_symbols([]), do: ""

  defp render_symbols(symbols) do
    Enum.map_join(symbols, "\n", fn %Symbol{} = s ->
      edges =
        [callers: s.callers, callees: s.callees]
        |> Enum.reject(fn {_label, list} -> list == [] end)
        |> Enum.map_join("; ", fn {label, list} -> "#{label}: #{Enum.join(list, ", ")}" end)

      base = "- #{s.name} (#{s.kind}) in #{s.path}"
      if edges == "", do: base, else: base <> " — " <> edges
    end)
  end

  defp render_test_sources([]), do: ""

  defp render_test_sources(sources) do
    Enum.map_join(sources, "\n\n", fn %FileRef{path: path, source: source} ->
      "### #{path}\n```\n#{source || ""}\n```"
    end)
  end
end
