defmodule Kazi.Enforcement.DiffGuard do
  @moduledoc """
  The ADVISORY diff-inspection gaming guard (T32.5, ADR-0042 §5).

  Before the loop credits an iteration as *progress*, this guard runs a cheap
  STRUCTURAL check on the agent's diff for the gaming SIGNATURES the research note
  catalogs (`docs/research/predicate-verification-landscape.md`): the agent editing
  the grader, special-casing a known test input, or sprinkling `skip`/`xfail`
  markers to make a suite green by not running. A hit is SURFACED as evidence and
  DOWNGRADES the iteration's progress — it never hard-blocks convergence or crashes
  the loop. The hard guarantees are the T32.4 ratchets + read-only lease; this is
  the cheap early-warning layer with a deliberately LOW false-positive bar
  (ADR-0042 "Consequences": "starting advisory — surface, don't block").

  ## What it inspects

  A unified diff (`git diff HEAD`, the agent's uncommitted iteration changes). Only
  ADDED lines (`+`, not the `+++` header) carry a signature — a pure deletion or a
  context line is never a skip/special-case signal — except `:grader_edit`, which
  fires on ANY change (add OR delete) to a grader/predicate path, since deleting a
  check is itself the exploit.

  ## The three signatures

    * `:skip_marker` — a newly-added skip/xfail/ignore/disabled marker across the
      common runners (pytest `@pytest.mark.skip`/`xfail`, `pytest.skip(`,
      `unittest.skip`, `raise SkipTest`; JS/TS `it.skip(`/`describe.skip(`/`xit(`;
      Go `t.Skip(`; Rust `#[ignore]`; JUnit `@Disabled`/`@Ignore`; ExUnit
      `@tag :skip`). Closes "make the suite pass by not running work".

    * `:test_special_casing` — an `if <input-ish> == <literal>` branch: hardcoding
      behaviour for a known test input ("`if input == <test_case>`"). Anchored to a
      small allowlist of input-ish identifiers so an ordinary `if mode == :create`
      refactor branch is NOT flagged (the low-false-positive bar).

    * `:grader_edit` — an add/delete touching a grader/predicate path. The precise
      set is the goal's `read_only_paths` (passed as `:grader_paths`); a small
      built-in heuristic also catches obviously-named predicate/grader files
      (`predicates.*`, `*.goal.toml`, a `grader`/`predicates` path segment) when
      nothing was formally leased.

  Pure: no I/O, no process state. The loop owns fetching the diff (the injectable
  `diff_fn`) and the side effect (appending the flagged events + downgrading the
  iteration's progress in the stuck classifier); this module only decides, given a
  diff, which signatures fire and where.
  """

  @typedoc """
  A flagged diff-gaming event. `signature` names which heuristic fired, `file`/
  `line` localize it (line is `nil` for a `:grader_edit` deletion with no added
  line), and `snippet` is the offending diff line, trimmed and length-capped, as
  human-readable evidence.
  """
  @type event :: %{
          type: :diff_gaming,
          signature: :skip_marker | :test_special_casing | :grader_edit,
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          snippet: String.t()
        }

  # A change record per file in the diff: the added lines (with their new-file line
  # numbers) and whether the file changed at all (added OR removed lines).
  @typep file_change :: %{
           file: String.t(),
           added: [{non_neg_integer(), String.t()}],
           changed?: boolean()
         }

  # The longest snippet retained as evidence — enough to read the offending line,
  # bounded so a minified/huge line can't bloat the `--json` gaming-events list.
  @snippet_cap 200

  # Skip / xfail / ignore / disabled markers across the common test runners. Each
  # is a substring (anchored loosely) matched against a trimmed added line.
  @skip_patterns [
    ~r/@pytest\.mark\.(skip|skipif|xfail)\b/,
    ~r/\bpytest\.(skip|xfail)\s*\(/,
    ~r/@unittest\.skip\b/,
    ~r/\bunittest\.skip\s*\(/,
    ~r/\.skipTest\s*\(/,
    ~r/\braise\s+SkipTest\b/,
    ~r/\b(it|test|describe|context)\.skip\s*\(/,
    ~r/\b(xit|xdescribe|xtest)\s*\(/,
    ~r/\bt\.Skip(f|Now)?\s*\(/,
    ~r/#\[\s*ignore\b/,
    ~r/@(Disabled|Ignore)\b/,
    ~r/@tag\s+:(skip|pending)\b/
  ]

  # Input-ish identifiers whose equality against a LITERAL reads as special-casing a
  # known test input rather than ordinary control flow. Kept small so a routine
  # `if mode == "create"` / `if status == :ok` branch never trips the guard.
  @input_idents ~w(input inputs arg args argument argv stdin payload request req
                   testcase test_input expected tc case n x)

  # `if <input-ish ident> == <string|number literal>` — single-line, conservative.
  @special_case_re Regex.compile!(
                     "\\bif\\b.*\\b(#{Enum.join(@input_idents, "|")})\\b\\s*===?\\s*(\"[^\"]*\"|'[^']*'|-?\\d+(\\.\\d+)?)"
                   )

  @doc """
  Scans a unified `diff` and returns the flagged gaming events (`[]` when clean).

  ## Options

    * `:grader_paths` — repo-relative grader/predicate paths (the goal's
      `read_only_paths`); a change touching one fires `:grader_edit`. Default `[]`.

  A non-binary diff (e.g. `nil` when no diff could be produced) yields `[]` — the
  guard is a no-op rather than an error, preserving the advisory contract.

  ## Examples

      iex> diff = "+++ b/test_widget.py\\n@@ -1,1 +1,2 @@\\n test\\n+@pytest.mark.skip\\n"
      iex> [event] = Kazi.Enforcement.DiffGuard.scan(diff)
      iex> {event.signature, event.file}
      {:skip_marker, "test_widget.py"}

      iex> Kazi.Enforcement.DiffGuard.scan("+++ b/lib/widget.ex\\n@@ -1 +1 @@\\n+  def add(a, b), do: a + b\\n")
      []
  """
  @spec scan(String.t() | nil, keyword()) :: [event()]
  def scan(diff, opts \\ [])

  def scan(diff, opts) when is_binary(diff) do
    grader_paths = Keyword.get(opts, :grader_paths, [])

    diff
    |> parse()
    |> Enum.flat_map(fn change -> classify(change, grader_paths) end)
  end

  def scan(_diff, _opts), do: []

  # ---------------------------------------------------------------------------
  # Parse: a unified diff → one file_change per touched file
  # ---------------------------------------------------------------------------

  @spec parse(String.t()) :: [file_change()]
  defp parse(diff) do
    {_state, files} =
      diff
      |> String.split("\n")
      |> Enum.reduce({%{file: nil, line: 0}, %{}}, &parse_line/2)

    files
    |> Map.values()
    |> Enum.reverse()
  end

  # `+++ b/<path>` — the authoritative NEW-file path; opens a fresh file record.
  defp parse_line("+++ b/" <> path, {state, files}) do
    open_file(String.trim(path), state, files)
  end

  # `+++ /dev/null` (file deleted) — fall back to the `diff --git` b-side path.
  defp parse_line("+++ " <> _rest, acc), do: acc

  # `diff --git a/<x> b/<y>` — set the pending file from the b-side so a delete with
  # `+++ /dev/null` still attributes its `-` lines; refined by a later `+++ b/`.
  defp parse_line("diff --git " <> rest, {state, files}) do
    case git_header_path(rest) do
      nil -> {state, files}
      path -> open_file(path, state, files)
    end
  end

  # `--- ...` (old-file header) carries no new-file info.
  defp parse_line("--- " <> _rest, acc), do: acc

  # `@@ -a,b +c,d @@` — reset the new-file line counter to the hunk's start line.
  defp parse_line("@@" <> rest, {state, files}) do
    {%{state | line: hunk_start(rest)}, files}
  end

  # An added line (but not the `+++` header): record it at the current new-file
  # line and advance the counter; mark the file changed.
  defp parse_line("+" <> content, {%{file: file, line: line} = state, files})
       when is_binary(file) do
    files = update_file(files, file, fn fc -> %{fc | added: [{line, content} | fc.added]} end)
    {%{state | line: line + 1}, files}
  end

  # A removed line (but not the `---` header): the file changed, but no new-file
  # line is consumed (the counter tracks the NEW side only).
  defp parse_line("-" <> _content, {%{file: file} = state, files}) when is_binary(file) do
    {state, mark_changed(files, file)}
  end

  # A context line advances the new-file counter without recording anything.
  defp parse_line(" " <> _content, {%{file: file, line: line} = state, files})
       when is_binary(file) do
    {%{state | line: line + 1}, files}
  end

  defp parse_line(_other, acc), do: acc

  # Open (or re-focus on) a file record, seeding it empty if unseen.
  defp open_file(path, state, files) do
    files =
      Map.put_new(files, path, %{file: path, added: [], changed?: false})

    {%{state | file: path, line: 0}, files}
  end

  defp update_file(files, file, fun) do
    fc = Map.get(files, file, %{file: file, added: [], changed?: false})
    Map.put(files, file, %{fun.(fc) | changed?: true})
  end

  defp mark_changed(files, file) do
    update_file(files, file, & &1)
  end

  # The b-side path of a `diff --git a/<x> b/<y>` header. Splits on " b/" so a path
  # with spaces on the a-side does not confuse it; returns nil if unparseable.
  defp git_header_path(rest) do
    case String.split(rest, " b/", parts: 2) do
      [_a, b] -> String.trim(b)
      _ -> nil
    end
  end

  # The +c of a `@@ -a,b +c,d @@` header (the new-file start line). Defaults to 1
  # when the header is malformed so line numbers stay sane rather than crash.
  defp hunk_start(rest) do
    case Regex.run(~r/\+(\d+)/, rest) do
      [_, n] -> String.to_integer(n)
      _ -> 1
    end
  end

  # ---------------------------------------------------------------------------
  # Classify: a file_change → its flagged events
  # ---------------------------------------------------------------------------

  @spec classify(file_change(), [String.t()]) :: [event()]
  defp classify(%{file: file, added: added, changed?: changed?}, grader_paths) do
    line_events =
      added
      |> Enum.reverse()
      |> Enum.flat_map(fn {line, content} -> line_events(file, line, content) end)

    grader_events =
      if changed? and grader_path?(file, grader_paths) do
        [event(:grader_edit, file, grader_line(added), grader_snippet(added, file))]
      else
        []
      end

    line_events ++ grader_events
  end

  # A single added line → its skip-marker / special-casing events (each line may
  # carry at most one of each signature).
  defp line_events(file, line, content) do
    trimmed = String.trim(content)

    []
    |> maybe(skip_marker?(trimmed), fn -> event(:skip_marker, file, line, trimmed) end)
    |> maybe(special_case?(trimmed), fn -> event(:test_special_casing, file, line, trimmed) end)
  end

  defp maybe(events, false, _fun), do: events
  defp maybe(events, true, fun), do: [fun.() | events]

  defp skip_marker?(line), do: Enum.any?(@skip_patterns, &Regex.match?(&1, line))

  defp special_case?(line), do: Regex.match?(@special_case_re, line)

  # A file is a grader/predicate path when it matches a configured grader path
  # (exact or a directory prefix) OR the conservative built-in name heuristic.
  defp grader_path?(file, grader_paths) do
    Enum.any?(grader_paths, fn gp -> file == gp or String.starts_with?(file, gp <> "/") end) or
      grader_name_heuristic?(file)
  end

  # Obvious predicate/grader file names, used only when nothing was formally leased
  # as read-only. Kept tight (basename + a path-segment check) to hold the
  # false-positive bar.
  defp grader_name_heuristic?(file) do
    base = Path.basename(file)
    segments = Path.split(file)

    String.starts_with?(base, "predicates") or
      String.ends_with?(base, ".goal.toml") or
      String.starts_with?(base, "grader") or
      Enum.any?(segments, &(&1 in ["graders", "predicates"]))
  end

  # The line number for a grader_edit: the first added line's number, or nil when
  # the change was a pure deletion (no added line to point at).
  defp grader_line([]), do: nil
  defp grader_line(added), do: added |> Enum.reverse() |> List.first() |> elem(0)

  defp grader_snippet([], file), do: "changed grader/predicate path #{file}"

  defp grader_snippet(added, _file) do
    added |> Enum.reverse() |> List.first() |> elem(1) |> String.trim()
  end

  defp event(signature, file, line, snippet) do
    %{
      type: :diff_gaming,
      signature: signature,
      file: file,
      line: line,
      snippet: cap(snippet)
    }
  end

  defp cap(snippet) when byte_size(snippet) <= @snippet_cap, do: snippet
  defp cap(snippet), do: binary_part(snippet, 0, @snippet_cap) <> "…"
end
