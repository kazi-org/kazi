defmodule Kazi.Loop.Digest do
  @moduledoc """
  The pure **working-set digest** carried across convergence iterations
  (T4.7, ADR-0010 §4; UC-022).

  Each `claude -p` iteration is *stateless* (ADR-0001): the harness keeps no
  conversation memory between dispatches, so by default every iteration
  re-discovers where the work lives. T4.7 closes that gap with **map memory, not
  conversation memory**: after an iteration the loop distills a compact note of
  *which files that iteration touched* and threads it into the NEXT iteration's
  prompt, so the next agent starts knowing where prior work landed without paying
  to re-explore the structure.

  ## Map memory, NOT conversation memory (the crux — ADR-0008)

  The digest carries ONLY the **working set** the harness reported touching — a
  bounded list of file paths (WHERE work happened). It deliberately carries
  **none** of the agent's transcript, reasoning, final result text, or
  "what-I-tried" narrative (WHAT was tried). That distinction is the whole point:

    * Carrying *where* work happened is map memory — a structural pointer that
      reorients the next stateless iteration without biasing it.
    * Carrying *what was tried* would be conversation memory, which re-introduces
      the anchoring ADR-0008 deliberately discards — the agent would fixate on a
      prior failed approach instead of re-deriving a fix from the live failing
      evidence.

  This is enforced *structurally*, not by convention: `from_result/2` reads the
  harness result's `:touched` key and NOTHING else. The result's `:result` (the
  agent's final text), `:output` (raw stdout/transcript), and every other field
  are never inspected, so no conversation text can reach the digest by
  construction.

  ## Bounded

  The digest is hard-bounded so it can never itself become the budget problem it
  exists to avoid (a runaway agent that touches thousands of files must not pour
  thousands of paths into the next prompt). `from_result/2` caps the working set
  to `:max_files` paths (default `#{20}`), keeping the most recently/first
  reported entries and dropping the rest behind a `(+N more)` count, and bounds
  the rendered section to a byte budget. The empty digest renders to nothing, so
  the FIRST iteration (no prior touched set) leaves the prompt byte-for-byte
  unchanged (back-compat).

  ## Purity

  Pure and total: no I/O, no clock, no loop state. The loop (`Kazi.Loop`) reads
  the touched set off the harness result and threads the digest through its
  `Data`; this module only decides what a bounded, transcript-free digest of that
  set looks like and how it renders into a prompt section. That keeps the
  map-memory rule unit-testable in isolation and impossible to silently couple to
  the state machine.
  """

  @typedoc """
  A bounded working-set digest: the files a prior iteration touched, plus the
  count of any paths dropped to honour the cap. `files` is already capped to
  `:max_files`; `dropped` is how many touched paths did not fit (≥ 0). The
  `empty/0` value (`files: []`, `dropped: 0`) renders to nothing.
  """
  @type t :: %__MODULE__{files: [String.t()], dropped: non_neg_integer()}

  defstruct files: [], dropped: 0

  # Default cap on the number of file paths carried in the digest. Sized so the
  # note reorients the next iteration without itself becoming a budget burden:
  # large enough to name a realistic edit footprint, small enough that a runaway
  # touch set is bounded behind a `(+N more)` count. Override per-call.
  @default_max_files 20

  # Default byte budget for the RENDERED section. A coarse backstop on top of the
  # file-count cap: even short paths, multiplied by a large cap, must not balloon
  # the prompt. The render is truncated to this many bytes (on a path boundary).
  @default_max_bytes 2_048

  @doc "The empty digest: no prior working set. Renders to nothing."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  True for the empty digest (no files carried). The loop uses this to leave the
  first iteration's prompt unchanged.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{files: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Distill a bounded working-set digest from a harness result — **map memory
  only**.

  Reads the result's `:touched` working set (a list of file paths, the shape
  `Kazi.Harness.ClaudeAdapter` surfaces from the `--output-format json` envelope,
  T4.1) and NOTHING ELSE. The agent's `:result` text, raw `:output` transcript,
  and every other field are never read, so no conversation memory can enter the
  digest by construction (ADR-0008 anti-anchoring).

  The touched set is normalised (strings only, trimmed, de-duplicated preserving
  order) and capped to `:max_files` (default `#{@default_max_files}`); any paths
  beyond the cap are counted in `:dropped`. A result that reports no touched set
  — `{:error, _}`, `{:ok, map}` without a `:touched` list, an empty list — yields
  the empty digest, so an iteration that reports nothing carries nothing forward.

  ## Options

    * `:max_files` — cap on the number of paths carried (default
      `#{@default_max_files}`). A non-positive cap yields the empty digest.

  ## Examples

      iex> Kazi.Loop.Digest.from_result({:ok, %{touched: ["lib/a.ex", "lib/b.ex"]}})
      %Kazi.Loop.Digest{files: ["lib/a.ex", "lib/b.ex"], dropped: 0}

      iex> Kazi.Loop.Digest.from_result({:ok, %{result: "I refactored the parser"}})
      %Kazi.Loop.Digest{files: [], dropped: 0}

      iex> Kazi.Loop.Digest.from_result({:error, :boom})
      %Kazi.Loop.Digest{files: [], dropped: 0}
  """
  @spec from_result(term(), keyword()) :: t()
  def from_result(result, opts \\ []) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    result |> touched_set() |> from_files(max_files)
  end

  @doc """
  Build a bounded digest directly from a list of file paths (map memory only).

  The list is normalised (strings only, trimmed, de-duplicated preserving order)
  and capped to `max_files`; the overflow count goes to `:dropped`. A
  non-positive cap (or an empty/garbage list) yields the empty digest. This is
  the cap/normalise core `from_result/2` delegates to; exposed so the loop (or a
  test) can build a digest from an already-extracted working set.
  """
  @spec from_files([String.t()] | term(), non_neg_integer()) :: t()
  def from_files(files, max_files) when is_list(files) and is_integer(max_files) do
    normalised = normalise(files)

    if max_files <= 0 do
      empty()
    else
      kept = Enum.take(normalised, max_files)
      %__MODULE__{files: kept, dropped: length(normalised) - length(kept)}
    end
  end

  def from_files(_files, _max_files), do: empty()

  @doc """
  Render the digest as a compact, prompt-ready **files-touched note** — or `""`
  for the empty digest, so the prompt is unchanged when there is no prior working
  set.

  The note carries ONLY file paths (map memory): a short header naming it as
  prior-iteration map memory, a bullet per file, and a `(+N more)` line when the
  cap dropped paths. It contains no transcript, reasoning, or result text — there
  is none in the digest to render.

  The whole section is bounded to `:max_bytes` (default `#{@default_max_bytes}`):
  if the bullets would exceed it, paths are dropped from the tail (folded into the
  `(+N more)` count) until the section fits, so even a maxed-out file list cannot
  blow the byte budget.

  ## Options

    * `:max_bytes` — byte ceiling on the rendered section (default
      `#{@default_max_bytes}`).

  ## Examples

      iex> Kazi.Loop.Digest.render(Kazi.Loop.Digest.empty())
      ""

      iex> d = %Kazi.Loop.Digest{files: ["lib/a.ex"], dropped: 2}
      iex> note = Kazi.Loop.Digest.render(d)
      iex> note =~ "lib/a.ex" and note =~ "+2 more"
      true
  """
  @spec render(t(), keyword()) :: String.t()
  def render(digest, opts \\ [])

  def render(%__MODULE__{files: []}, _opts), do: ""

  def render(%__MODULE__{files: files, dropped: dropped}, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    {kept, extra} = fit_to_bytes(files, dropped, max_bytes)
    render_note(kept, extra)
  end

  # =============================================================================
  # Internal
  # =============================================================================

  # Map memory ONLY: the working set is read from the result's `:touched` key and
  # nowhere else. No clause inspects `:result`, `:output`, or any other field, so
  # the agent's transcript/reasoning cannot reach the digest. A result that
  # carries no `:touched` list (an error, or a success envelope without one)
  # contributes the empty list.
  @spec touched_set(term()) :: [term()]
  defp touched_set({:ok, %{touched: touched}}) when is_list(touched), do: touched
  defp touched_set(_result), do: []

  # Clean a raw touched set into ordered, unique, non-empty path strings. Anything
  # non-binary (or blank after trimming) is dropped, so a surprising envelope
  # never injects garbage into the prompt.
  @spec normalise([term()]) :: [String.t()]
  defp normalise(files) do
    files
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Bound the rendered section to a byte budget by dropping paths from the tail
  # (folding them into the dropped count) until the bullets fit. Always keeps at
  # least one path once there is any, so the note never degrades to a bare header.
  @spec fit_to_bytes([String.t()], non_neg_integer(), non_neg_integer()) ::
          {[String.t()], non_neg_integer()}
  defp fit_to_bytes(files, dropped, max_bytes) do
    fit_to_bytes(files, dropped, max_bytes, length(files))
  end

  defp fit_to_bytes(files, dropped, max_bytes, take) when take >= 1 do
    kept = Enum.take(files, take)
    extra = dropped + (length(files) - take)

    if byte_size(render_note(kept, extra)) <= max_bytes or take == 1 do
      {kept, extra}
    else
      fit_to_bytes(files, dropped, max_bytes, take - 1)
    end
  end

  # Render the compact note from already-bounded inputs. The header names this as
  # map memory (so a reader knows it is structural, not a transcript), one bullet
  # per path, and a trailing `(+N more)` only when paths were dropped.
  @spec render_note([String.t()], non_neg_integer()) :: String.t()
  defp render_note(files, dropped) do
    bullets = Enum.map_join(files, "\n", &"- #{&1}")
    more = if dropped > 0, do: "\n- (+#{dropped} more)", else: ""

    "# Working set (prior iteration, map memory only)\n" <>
      "Files touched in the previous iteration — start here; the live failing " <>
      "evidence below is the source of truth.\n" <>
      bullets <> more
  end
end
