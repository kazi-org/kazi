defmodule Kazi.Providers.ProdLog do
  @moduledoc """
  The `:prod_log` predicate provider (T1.6): queries production logs over a recent
  time window and maps their cleanliness to a `Kazi.PredicateResult` (ADR-0002,
  UC-021).

  This is the live-evidence provider that proves a deploy is *behaving* in
  production, not merely reachable (concept §3, §5): a predicate's truth is the
  count of 5xx responses and panics observed in real logs over a window, not an
  agent's opinion. Clean logs (no panics, 5xx at/under threshold) are a `:pass`;
  logs exceeding the threshold or carrying a panic are real failing work
  (`:fail`); an inability to fetch the logs at all (binary missing, bad config,
  query error) is an `:error`, never a `:fail` — conflating the two would
  dispatch a fixer agent against an infra problem (`Kazi.PredicateResult`,
  ADR-0002).

  This provider is now a **preset** over the unified command-runner core (T32.1b,
  ADR-0040 decision 1): `prod_log` == `custom_script` with a regex-match-count
  verdict over the command's output, sharing the execution engine
  (`Kazi.Providers.CommandRunner`) with `custom_script` / `test_runner` while
  keeping its production-log-shaped evidence (5xx / panic counts).

  > #### Deprecated alias {: .warning}
  >
  > The `prod_log` provider name is **deprecated** (ADR-0040 decision 7) and
  > scheduled for removal in **v2.0.0**. It keeps working through the migration
  > window as this preset; new goals can express the same check as
  > `provider = "custom_script"` with `verdict = "match_count"`. See
  > `docs/deprecations.md`. The loader emits a one-line migration hint to STDERR
  > when a goal still uses the alias.

  ## Config

  The predicate's `config` map carries the log query (run via `System.cmd/3`,
  the same boundary the test-runner uses so it stays testable) and the
  cleanliness thresholds:

    * `:cmd`           — the log-fetch executable (string). Required. The genuine
      default a goal authors is a real query, e.g.
      `cmd: "gcloud", args: ["logging", "read", ...]`.
    * `:args`          — argument list (list of strings). Optional, defaults `[]`.
    * `:env`           — extra environment as `{name, value}` pairs. Optional.
    * `:window_minutes`— the recent window the query covers, recorded in evidence
      so the proof states *what span* it speaks for. Optional; informational only
      (the query itself bounds the window — kazi does not rewrite the command).
    * `:max_5xx`       — the maximum tolerated count of 5xx lines (integer).
      Optional, defaults `0` (any 5xx fails).
    * `:server_error_regex` — regex (string) marking a 5xx log line. Optional;
      defaults to a pattern matching a ` 5xx ` / `status: 5NN` style server error.
    * `:panic_regex`   — regex (string) marking a panic / crash line. Optional;
      defaults to `panic`. Any match fails regardless of `:max_5xx`.
    * `:correlate`     — optional trust-check (T41.5, ADR-0051 decision 4). An
      inline table `{route, window}`. When present, the fetched log lines are
      cross-checked for the given `route`, and a line on that route that also
      matches the 5xx or panic pattern sets a `correlated_prod_error: true`
      evidence flag. This DOWNGRADES TRUST in a green rather than the verdict —
      the verdict is unchanged (a `:pass` stays `:pass`), so the flag surfaces "a
      production error is happening on a route you named" instead of silently
      trusting the pass. `route` is matched as a literal substring of a log line;
      `window` is recorded in evidence (the span the correlation speaks for) but
      not used for filtering — the query already bounds the window, exactly like
      `:window_minutes`. Absent `:correlate`, evidence is byte-identical to a
      goal that never named it (a pure, opt-in add).

  ## Context

  `context[:workspace]` is the directory the query command runs in (`cd:`), so a
  relative or workspace-scoped query resolves against the same tree the harness
  edits. Defaults to the current directory when absent (mirrors
  `Kazi.Providers.TestRunner`).

  ## Evidence

  Every result carries the proof a fixer agent needs (ADR-0002): the resolved
  `:cmd`, `:args`, `:workspace`, and `:window_minutes` (the query used and the
  span it covers); on a completed query the `:server_error_count`, `:panic_count`,
  the `:max_5xx` threshold, and a bounded sample of the `:matched_lines`; on a
  provider error a `:reason`. When `:correlate` is configured, the completed-query
  evidence additionally carries `:correlate` (the `%{route, window}` it checked),
  `:correlated_prod_error` (whether a matching error was found on that route), and
  a bounded sample of `:correlated_lines`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  # Keep the sample seed-sized: enough matched lines to orient a fixer, not a
  # full log dump.
  @sample_limit 20
  @default_max_5xx 0
  # A 5xx line in common log formats: an HTTP status in the 500-599 range,
  # whether bare (` 503 `) or labelled (`status=500`, `status: 502`).
  @default_server_error_regex ~S/(?:\bstatus[=: ]+|[\s"])(5\d{2})(?:\b|")/
  @default_panic_regex ~S/panic/

  @impl true
  def evaluate(%Predicate{kind: :prod_log, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    with {:ok, cmd, args} <- fetch_cmd(config),
         {:ok, server_re} <-
           compile_regex(config, :server_error_regex, @default_server_error_regex),
         {:ok, panic_re} <- compile_regex(config, :panic_regex, @default_panic_regex) do
      query(cmd, args, workspace, config, server_re, panic_re)
    else
      {:error, reason} ->
        PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # Resolves the log-fetch command, rejecting a missing/blank :cmd before we ever
  # shell out so a malformed predicate is an :error, not a crash (mirrors
  # Kazi.Providers.TestRunner).
  defp fetch_cmd(config) do
    case config[:cmd] do
      cmd when is_binary(cmd) and cmd != "" ->
        {:ok, cmd, List.wrap(config[:args] || [])}

      nil ->
        {:error, :missing_cmd}

      other ->
        {:error, {:invalid_cmd, other}}
    end
  end

  # Compile an optional regex from config; a bad pattern is a config (:error)
  # problem, not failing work.
  defp compile_regex(config, key, default) do
    pattern =
      case Map.get(config, key) do
        nil -> default
        value when is_binary(value) -> value
        other -> {:invalid, other}
      end

    case pattern do
      {:invalid, other} ->
        {:error, {:invalid_regex, key, other}}

      source ->
        case Regex.compile(source) do
          {:ok, regex} -> {:ok, regex}
          {:error, reason} -> {:error, {:invalid_regex, key, reason}}
        end
    end
  end

  # Run the log query in the workspace via the shared command-runner core (T32.1b,
  # ADR-0040 decision 1) — the one engine custom_script/test_runner also use —
  # capturing stdout+stderr together so the evidence is the same stream an operator
  # would read. A command that could not be started (binary missing, bad cwd) is an
  # infra `:error`, never a `:fail` about production logs.
  defp query(cmd, args, workspace, config, server_re, panic_re) do
    opts = [cd: workspace, stderr_to_stdout: true]
    opts = if env = config[:env], do: Keyword.put(opts, :env, env), else: opts

    case CommandRunner.run(cmd, args, opts) do
      {:ran, output, 0} ->
        classify(output, cmd, args, workspace, config, server_re, panic_re)

      {:ran, output, exit_code} ->
        # The query command itself failed (auth, bad flags): an infra/config
        # problem, not a claim about production logs.
        PredicateResult.error(%{
          reason: {:query_failed, exit_code},
          cmd: cmd,
          args: args,
          workspace: workspace,
          output: output
        })

      {:raised, message} ->
        PredicateResult.error(%{
          reason: {:cmd_unrunnable, message},
          cmd: cmd,
          args: args,
          workspace: workspace
        })
    end
  end

  # Scan the fetched log output: a panic anywhere fails; a 5xx count over the
  # configured threshold fails; otherwise the window is clean and passes.
  defp classify(output, cmd, args, workspace, config, server_re, panic_re) do
    lines = String.split(output, "\n", trim: true)

    server_errors = Enum.filter(lines, &Regex.match?(server_re, &1))
    panics = Enum.filter(lines, &Regex.match?(panic_re, &1))

    max_5xx = max_5xx(config)
    over_5xx? = length(server_errors) > max_5xx
    has_panic? = panics != []

    evidence = %{
      cmd: cmd,
      args: args,
      workspace: workspace,
      window_minutes: Map.get(config, :window_minutes),
      max_5xx: max_5xx,
      server_error_count: length(server_errors),
      panic_count: length(panics),
      matched_lines: sample(panics ++ server_errors)
    }

    evidence = maybe_correlate(evidence, config, lines, server_re, panic_re)

    if over_5xx? or has_panic? do
      PredicateResult.fail(evidence)
    else
      PredicateResult.pass(evidence)
    end
  end

  # T41.5 (ADR-0051 decision 4): opt-in prod-log correlation. Absent `:correlate`,
  # this returns the evidence UNTOUCHED — byte-identical to before, the regression
  # guard. When configured, it cross-checks the already-fetched log lines for the
  # named route and flags a matching 5xx/panic: "a production error is happening on
  # a route you named", surfaced on the evidence so the loop does not silently
  # trust an otherwise-green predicate. It NEVER changes the verdict — the flag
  # downgrades trust in the green, not the verdict (the base check still owns
  # pass/fail).
  #
  # `route` matches as a literal substring (a route path is a literal, not a
  # pattern — no regex-injection footgun). `window` is recorded for the operator
  # but not used to filter: the query already bounds the window, so kazi does no
  # time math, exactly as it does not for `:window_minutes`.
  defp maybe_correlate(evidence, config, lines, server_re, panic_re) do
    case Map.get(config, :correlate) do
      correlate when is_map(correlate) ->
        route = correlate_field(correlate, "route")
        window = correlate_field(correlate, "window")

        correlated =
          if is_binary(route) and route != "" do
            Enum.filter(lines, fn line ->
              String.contains?(line, route) and
                (Regex.match?(server_re, line) or Regex.match?(panic_re, line))
            end)
          else
            []
          end

        Map.merge(evidence, %{
          correlate: %{route: route, window: window},
          correlated_prod_error: correlated != [],
          correlated_lines: sample(correlated)
        })

      _ ->
        evidence
    end
  end

  # Read a `correlate` sub-key. The nested table arrives STRING-keyed (the loader
  # atomizes only top-level predicate keys — see Kazi.Providers.Ratchet's
  # normalize_metric), but a programmatically-built config (a test, an MCP inline
  # goal) may pass atom keys, so accept either. No new atoms are created.
  defp correlate_field(correlate, key) when is_binary(key) do
    case Map.fetch(correlate, key) do
      {:ok, value} -> value
      :error -> Map.get(correlate, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  defp max_5xx(config) do
    case Map.get(config, :max_5xx, @default_max_5xx) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max_5xx
    end
  end

  defp sample(lines), do: Enum.take(lines, @sample_limit)
end
