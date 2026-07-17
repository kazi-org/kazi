defmodule Kazi.Providers.OssHygiene do
  @moduledoc """
  The `:oss_hygiene` predicate (T44.7, UC-058): the E29/ADR-0034 internal-leak
  guard as a first-class kazi predicate.

  A public repo must not leak internal-only markers. This provider ports the exact
  scanning logic of `.github/scripts/no_internal_leak_guard.sh` (the "no
  internal-info leak" CI gate) into Elixir, so a goal can hold the same bar the CI
  gate does: it scans the ADDED lines of the diff between a base ref and `HEAD` for

    * **private IPv4** (RFC-1918): `192.168.*`, `10.*`, `172.16-31.*`;
    * **absolute home paths**: `/Users/<name>/…`, `/home/<name>/…`;
    * **internal codenames**: a per-goal **configurable** list (`codenames`), so a
      repo names its own internal terms without hardcoding them into this public
      file (which would itself leak them).

  A hit is a `:fail` naming the exact `path:line` and the offending line; a scrubbed
  diff is `:pass`. An inability to compute the diff (not a git repo, base ref
  unresolvable) is `:error`, never `:fail` (ADR-0002).

  ## Allow-list (kept in lockstep with the CI script)

  Legitimate cases pass: RFC-5737 example IPs (`192.0.2.*`, `198.51.100.*`,
  `203.0.113.*`), loopback/unspecified (`127.0.0.1`, `0.0.0.0`), documentation
  placeholder home paths (`/Users/<name>`, `/home/USER`, …), and any line carrying
  the inline `leak-guard:allow` marker.

  ## Config

    * `codenames` — a list of internal codename strings to flag (default `[]`),
      matched case-insensitively as whole-ish tokens.
    * `base_ref` — the ref the diff is taken against (default `"origin/main"`).
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  @default_base "origin/main"
  @allow_marker "leak-guard:allow"

  # Private IPv4 (RFC-1918): the 192.168, 10, and 172.16-31 private ranges.
  @private_ip ~r/(^|[^0-9.])(192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})([^0-9]|$)/

  # Absolute home paths with a real user token (not a placeholder).
  @home_path ~r{(/Users/|/home/)[A-Za-z0-9_][A-Za-z0-9_.-]*}

  # RFC-5737 example ranges + loopback/unspecified — stripped before the private
  # check so a line that ONLY contains allow-listed tokens does not trip it.
  @allow_ip ~r/(192\.0\.2\.\d{1,3}|198\.51\.100\.\d{1,3}|203\.0\.113\.\d{1,3}|127\.0\.0\.1|0\.0\.0\.0)/

  # Documentation placeholders: an angle-bracket placeholder or an all-caps token.
  @allow_home ~r{/(Users|home)/(<[A-Za-z0-9_-]+>|NAME|USER|USERNAME|YOU)([/ ]|$)}

  # The added-line block start (new-file line number) of a unified-diff hunk.
  @hunk ~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/

  @impl true
  def evaluate(%Predicate{kind: :oss_hygiene, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()
    base = config[:base_ref] || @default_base
    codenames = config[:codenames] || []

    case diff(context, workspace, base) do
      {:ok, diff_text} ->
        result(scan_diff(diff_text, codenames), base)

      {:error, reason} ->
        PredicateResult.error(%{reason: reason, base: base, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  @doc """
  Scans a unified diff's ADDED lines for internal-leak markers.

  Pure — the scanning half, separated from the git I/O. Returns the list of hits,
  each `%{path:, line:, content:, kind:}` where `kind` is `:private_ip`,
  `:home_path`, or `:codename`.
  """
  @spec scan_diff(String.t(), [String.t()]) :: [map()]
  def scan_diff(diff_text, codenames) when is_binary(diff_text) and is_list(codenames) do
    diff_text
    |> String.split("\n")
    |> Enum.reduce(%{path: nil, line: 0, hits: []}, fn dl, state ->
      scan_line(dl, state, codenames)
    end)
    |> Map.fetch!(:hits)
    |> Enum.reverse()
  end

  # +++ b/<path> sets the current file; +++ /dev/null (a deletion) clears it.
  defp scan_line("+++ b/" <> path, state, _codenames), do: %{state | path: path, line: 0}
  defp scan_line("+++ " <> _rest, state, _codenames), do: %{state | path: nil, line: 0}

  # A hunk header resets the new-file line counter to the added block's start.
  defp scan_line("@@" <> _ = dl, state, _codenames) do
    case Regex.run(@hunk, dl) do
      [_, start] -> %{state | line: String.to_integer(start)}
      _ -> state
    end
  end

  # An added line (not the +++ header): test it, then advance the counter.
  defp scan_line("+" <> content, %{path: path, line: line} = state, codenames)
       when is_binary(path) do
    state =
      case leak_kind(content, codenames) do
        nil ->
          state

        kind ->
          %{state | hits: [%{path: path, line: line, content: content, kind: kind} | state.hits]}
      end

    %{state | line: line + 1}
  end

  # A context line (unified > 0) advances the new-file counter; a deletion does not.
  defp scan_line(" " <> _rest, %{line: line} = state, _codenames), do: %{state | line: line + 1}
  defp scan_line(_dl, state, _codenames), do: state

  @doc """
  The leak kind of a single line, or `nil` if it is clean.

  Mirrors the CI guard's `is_leak_line`: the inline allow marker exempts the whole
  line; allow-listed IPs/home placeholders are stripped before the private-pattern
  checks; then private IP, home path, and each configured codename are tried.
  """
  @spec leak_kind(String.t(), [String.t()]) :: :private_ip | :home_path | :codename | nil
  def leak_kind(line, codenames) when is_binary(line) do
    if String.contains?(line, @allow_marker) do
      nil
    else
      stripped =
        line
        |> then(&Regex.replace(@allow_ip, &1, "__ALLOWED_IP__"))
        |> then(&Regex.replace(@allow_home, &1, "__ALLOWED_HOME__"))

      cond do
        Regex.match?(@private_ip, stripped) -> :private_ip
        Regex.match?(@home_path, stripped) -> :home_path
        codename_hit?(stripped, codenames) -> :codename
        true -> nil
      end
    end
  end

  defp codename_hit?(line, codenames) do
    Enum.any?(codenames, fn name ->
      name != "" and
        Regex.match?(~r/(^|[^A-Za-z0-9])#{Regex.escape(name)}([^A-Za-z0-9]|$)/i, line)
    end)
  end

  # ── result + git I/O ────────────────────────────────────────────────────────

  defp result([], base) do
    PredicateResult.new(:pass, %{hits: [], count: 0, base: base},
      score: 0.0,
      direction: :lower_better
    )
  end

  defp result(hits, base) do
    count = length(hits)

    PredicateResult.new(:fail, %{hits: hits, count: count, base: base},
      score: count * 1.0,
      direction: :lower_better
    )
  end

  # The diff of ADDED lines vs the merge-base of `base` and HEAD. An injectable
  # `:diff_fn` (a 0-arity fun) is the test seam; production shells out to git.
  defp diff(context, workspace, base) do
    case context[:diff_fn] do
      fun when is_function(fun, 0) -> fun.()
      _ -> git_diff(workspace, base)
    end
  end

  defp git_diff(workspace, base) do
    case resolve_base(workspace, base) do
      {:ok, base_sha} ->
        case System.cmd("git", ["diff", "--unified=0", "#{base_sha}...HEAD"],
               cd: workspace,
               stderr_to_stdout: true
             ) do
          {out, 0} -> {:ok, out}
          {out, _} -> {:error, {:git_diff_failed, String.trim(out)}}
        end

      :error ->
        {:error, {:base_unresolvable, base}}
    end
  rescue
    error -> {:error, {:git_unavailable, Exception.message(error)}}
  end

  defp resolve_base(workspace, base) do
    with {_, 0} <- System.cmd("git", ["rev-parse", "--verify", "--quiet", base], cd: workspace),
         {sha, 0} <- merge_base(workspace, base) do
      {:ok, String.trim(sha)}
    else
      _ -> :error
    end
  end

  defp merge_base(workspace, base) do
    case System.cmd("git", ["merge-base", base, "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {sha, 0} -> {sha, 0}
      _ -> System.cmd("git", ["rev-parse", base], cd: workspace, stderr_to_stdout: true)
    end
  end
end
