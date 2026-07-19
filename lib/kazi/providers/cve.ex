defmodule Kazi.Providers.Cve do
  @moduledoc """
  The `:cve` predicate provider (T32.8, ADR-0043): dependency vulnerability
  scanning, led by `govulncheck` REACHABILITY.

  Most SCA tooling reports every vuln present in the dependency MANIFEST — a CLAIM
  ("you depend on something with a known CVE") that is mostly noise: the vulnerable
  symbol is usually never called. `govulncheck` is different: it does call-graph
  reachability and reports a vuln only when the vulnerable function is TRANSITIVELY
  CALLED, printing the call stack as proof. That is a DEMONSTRATION (ADR-0043
  decision 4) — safe to fail a loop on directly, because the call stack IS the fix
  context.

  So this provider has two tiers:

    * **tier 1 — `govulncheck` reachability (default).** Parse the JSON finding
      stream; a finding is REACHABLE iff its `trace` leaf frame carries a
      `function` (the vulnerable symbol is actually called, not merely imported).
      `:fail` iff ≥1 reachable vuln, with the call stack as evidence. `score` =
      reachable count (`direction: :lower_better`).
    * **tier 2 — manifest scanners (`trivy`/`grype`/`npm_audit`).** These report
      presence, not reachability — CLAIMS. They are ratcheted against a baseline so
      security DEBT can only shrink (you are not blocked on pre-existing debt, but
      a NEW vuln fails). `score` = the vuln count (`direction: :lower_better`).

  ## The exit-code gotcha (lore L-0015)

  The verdict is read from the PARSED output, NEVER the exit code. `govulncheck
  -json` exits `0` EVEN WITH vulns (the JSON mode suppresses the failure code);
  trusting the exit code would false-pass. Conversely `npm audit`/`grype` exit
  NON-zero WITH findings, so the tier-2 count is parsed exit-code-agnostically too.
  The only `:error` path is a non-zero exit with NO parseable output (the tool
  could not run).

  ## Config

    * `:tool` — `"govulncheck"` (default, tier 1), `"trivy"`, `"grype"`, or
      `"npm_audit"` (tier 2). Selects the parser + tier.
    * `:cmd`  — the executable. Optional; defaults to the tool's binary
      (`govulncheck`/`trivy`/`grype`, and `npm` for `npm_audit`).
    * `:args` — argument list. Optional; defaults to the tool's JSON-output
      invocation.
    * `:env`  — extra environment, a `{name, value}` list or a `{name => value}`
      map. Optional.
    * `:timeout_ms` — kill the command after this many ms and map it to `:error`.
      Optional; absent means no timeout.

  Tier 2 only:

    * `:count_path` — a `Kazi.JSONPath` over stdout to the vulnerability COUNT
      (e.g. `"$.metadata.vulnerabilities.total"` for `npm audit`). Required for the
      manifest tools.
    * `:baseline` — the bar: a number (the allowed max count) or `"stored"`/`"prior"`
      (the last passing count, persisted and tightened on a pass — first run seeds
      it). Default `0` ("no known vulns").
    * `:allowed_regression` — the tolerated increase over baseline. Default `0`.
    * `:store_dir` / `:id` — the stored-baseline store dir + key.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`). Defaults to
  the current directory when absent. `context[:ratchet_store_dir]` overrides the
  tier-2 stored-baseline directory.

  ## Evidence

  Tier 1 carries the `:tool`, the `:reachable` count, and a bounded `:findings`
  list — each with the `:osv` id, the `:call_stack` (frames leaf→root), and the
  vulnerable `:file`/`:line`. Tier 2 carries the `:tool`, the parsed `:count`, the
  resolved `:baseline`, and the `:regression`. An `:error` carries a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult, Ratchet}
  alias Kazi.Providers.CommandRunner
  alias Kazi.Ratchet.Store

  @output_limit 4_000
  @finding_sample_limit 25

  @tools ~w(govulncheck trivy grype npm_audit)
  @tier1 ~w(govulncheck)

  # The default invocation per tool — the JSON-output form (the only form whose
  # parse is reliable; see the exit-code gotcha, L-0015).
  @defaults %{
    "govulncheck" => {"govulncheck", ["-json", "./..."]},
    "trivy" => {"trivy", ["fs", "--format", "json", "."]},
    "grype" => {"grype", ["-o", "json", "."]},
    "npm_audit" => {"npm", ["audit", "--json"]}
  }

  @doc "The vulnerability tools this provider supports."
  @spec tools() :: [String.t()]
  def tools, do: @tools

  @impl true
  def evaluate(%Predicate{kind: :cve, id: id, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()
    tool = tool(config)
    {default_cmd, default_args} = Map.fetch!(@defaults, tool)
    cmd = cmd(config, default_cmd)
    args = args(config, default_args)

    opts = [cd: workspace, stderr_to_stdout: false] ++ env_opt(config)

    case CommandRunner.run(cmd, args, opts, Map.get(config, :timeout_ms)) do
      {:ran, output, exit_code} ->
        decide(tool, output, exit_code, %{id: id, config: config, context: context, tool: tool})

      {:raised, message} ->
        PredicateResult.error(%{
          reason: {:cmd_unrunnable, message},
          cmd: cmd,
          workspace: workspace
        })

      {:timeout, ms} ->
        PredicateResult.error(%{reason: {:timeout_ms, ms}, cmd: cmd, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  defp decide(tool, output, exit_code, ctx) when tool in @tier1 do
    decide_reachability(output, exit_code, ctx)
  end

  defp decide(_tool, output, exit_code, ctx) do
    decide_manifest(output, exit_code, ctx)
  end

  # =============================================================================
  # Tier 1 — govulncheck reachability
  # =============================================================================

  # Gate on the PARSED finding stream, NOT the exit code (govulncheck -json exits 0
  # even with vulns, L-0015). A non-zero exit with NO parseable objects is the only
  # :error path (the tool could not run); otherwise the reachable findings decide.
  defp decide_reachability(output, exit_code, ctx) do
    case decode_stream(output) do
      [] when exit_code != 0 ->
        PredicateResult.error(%{
          reason: {:tool_unrunnable, exit_code},
          tool: ctx.tool,
          output: truncate(output)
        })

      objects ->
        reachable = objects |> findings() |> Enum.filter(&reachable?/1) |> Enum.map(&summarize/1)
        count = length(reachable)

        evidence = %{
          tool: ctx.tool,
          reachable: count,
          findings: Enum.take(reachable, @finding_sample_limit),
          output: truncate(output)
        }

        status = if count == 0, do: :pass, else: :fail

        PredicateResult.new(status, evidence,
          score: count * 1.0,
          direction: :lower_better,
          diagnostics: Enum.map(reachable, &diagnostic/1)
        )
    end
  end

  # govulncheck emits a stream of objects keyed config/progress/osv/finding; we
  # want the finding records (the vuln instances, each carrying a call-stack trace).
  defp findings(objects) do
    Enum.flat_map(objects, fn
      %{"finding" => finding} when is_map(finding) -> [finding]
      _ -> []
    end)
  end

  # A finding is REACHABLE iff its trace's LEAF frame (the most specific, the
  # vulnerable symbol) carries a `function` — i.e. the vulnerable code is actually
  # CALLED, not merely imported/required (L-0015).
  defp reachable?(%{"trace" => [%{"function" => fun} | _]}) when is_binary(fun) and fun != "",
    do: true

  defp reachable?(_), do: false

  # Flatten a reachable finding into the proof: the OSV id, the call stack (leaf→
  # root as `function@package`), and the vulnerable file:line from the leaf frame.
  defp summarize(%{"trace" => [leaf | _] = trace} = finding) do
    %{
      osv: Map.get(finding, "osv"),
      fixed_version: Map.get(finding, "fixed_version"),
      call_stack: Enum.map(trace, &frame_label/1),
      file: get_in(leaf, ["position", "filename"]),
      line: get_in(leaf, ["position", "line"])
    }
  end

  defp frame_label(frame) do
    fun = Map.get(frame, "function")
    pkg = Map.get(frame, "package") || Map.get(frame, "module")

    case {fun, pkg} do
      {f, p} when is_binary(f) and is_binary(p) -> "#{f}@#{p}"
      {f, _} when is_binary(f) -> f
      {_, p} when is_binary(p) -> p
      _ -> "?"
    end
  end

  defp diagnostic(reachable) do
    Kazi.Evidence.new(
      rule: reachable.osv,
      level: :error,
      file: reachable.file,
      line: reachable.line,
      message:
        "reachable vulnerability #{reachable.osv} (called via #{Enum.join(reachable.call_stack, " <- ")})"
    )
  end

  # =============================================================================
  # Tier 2 — manifest scanners, count ratcheted vs a baseline
  # =============================================================================

  # Parse the vuln COUNT exit-code-agnostically (trivy/grype/npm-audit each exit on
  # their own convention WITH findings — L-0015), then ratchet it against the
  # baseline (lower_better). A parse failure / missing count is an :error.
  defp decide_manifest(output, exit_code, ctx) do
    path = Map.get(ctx.config, :count_path)

    with {:ok, count} <- parse_count(output, path) do
      ratchet_count(count, ctx)
    else
      {:error, reason} ->
        PredicateResult.error(%{
          reason: reason,
          tool: ctx.tool,
          exit: exit_code,
          output: truncate(output)
        })
    end
  end

  defp parse_count(_output, path) when not is_binary(path), do: {:error, :missing_count_path}

  defp parse_count(output, path) do
    with {:ok, data} <- decode_json(output),
         {:ok, raw} <- Kazi.JSONPath.get(data, path),
         {:ok, number} <- Kazi.JSONPath.to_number(raw) do
      {:ok, number}
    end
  end

  # Reuse the ratchet PURE helpers (lower_better): pass iff the count's increase
  # over the baseline is within allowed_regression. A "stored" baseline seeds on the
  # first run and tightens (min) on a pass; a numeric baseline is a fixed max.
  defp ratchet_count(count, ctx) do
    allowed = numeric(Map.get(ctx.config, :allowed_regression, 0.0)) || 0.0

    case resolve_baseline(count, ctx) do
      {:seed, store_dir, key} ->
        Store.write(store_dir, key, count)
        manifest_result(:pass, count, count, allowed, :seed, ctx)

      {:ok, source, baseline, maybe_store} ->
        status = Ratchet.verdict(count, baseline, allowed, :lower_better)
        maybe_tighten(status, source, count, baseline, maybe_store)
        manifest_result(status, count, baseline, allowed, source, ctx)
    end
  end

  defp resolve_baseline(_count, ctx) do
    case Map.get(ctx.config, :baseline, 0) do
      n when is_number(n) ->
        {:ok, :literal, n * 1.0, nil}

      s when is_binary(s) ->
        store_dir = store_dir(ctx)
        key = ctx.config[:id] || ctx.id

        case Store.read(store_dir, key) do
          {:ok, value} -> {:ok, :stored, value, {store_dir, key}}
          :none -> {:seed, store_dir, key}
        end

      _ ->
        {:ok, :literal, 0.0, nil}
    end
  end

  defp maybe_tighten(:pass, :stored, count, baseline, {store_dir, key}) do
    Store.write(store_dir, key, Ratchet.tighten(baseline, count, :lower_better))
  end

  defp maybe_tighten(_status, _source, _count, _baseline, _store), do: :ok

  defp manifest_result(status, count, baseline, allowed, source, ctx) do
    evidence = %{
      tool: ctx.tool,
      count: count,
      baseline: baseline,
      baseline_source: source,
      regression: Ratchet.regression(count, baseline, :lower_better),
      allowed_regression: allowed
    }

    PredicateResult.new(status, evidence, score: count * 1.0, direction: :lower_better)
  end

  defp store_dir(ctx) do
    ctx.config[:store_dir] || ctx.context[:ratchet_store_dir] ||
      Path.join(ctx.context[:workspace] || File.cwd!(), ".kazi")
  end

  # =============================================================================
  # JSON stream splitting (govulncheck emits concatenated objects, not one doc)
  # =============================================================================

  @doc false
  # Split a stream of concatenated top-level JSON objects into a list of decoded
  # maps, dropping any fragment that does not decode. A brace-depth scanner that
  # respects strings + escapes, so braces inside string values never split an
  # object (govulncheck `-json` emits pretty-printed objects back to back).
  @spec decode_stream(String.t()) :: [map()]
  def decode_stream(output) when is_binary(output) do
    output
    |> split_objects()
    |> Enum.flat_map(fn obj ->
      case Jason.decode(obj) do
        {:ok, map} -> [map]
        {:error, _} -> []
      end
    end)
  end

  defp split_objects(output) do
    output
    |> String.to_charlist()
    |> Enum.reduce({[], [], 0, false, false}, &scan_char/2)
    |> finish_objects()
  end

  # State: {completed_objects, current_chars (reversed), depth, in_string?, escaped?}.
  defp scan_char(char, {objs, cur, depth, true, true}) do
    # Inside a string, previous char was a backslash: this char is escaped.
    {objs, [char | cur], depth, true, false}
  end

  defp scan_char(?\\, {objs, cur, depth, true, false}) do
    {objs, [?\\ | cur], depth, true, true}
  end

  defp scan_char(?", {objs, cur, depth, true, false}) do
    {objs, [?" | cur], depth, false, false}
  end

  defp scan_char(char, {objs, cur, depth, true, false}) do
    {objs, [char | cur], depth, true, false}
  end

  defp scan_char(?", {objs, cur, depth, false, _}) do
    {objs, [?" | cur], depth, true, false}
  end

  defp scan_char(?{, {objs, cur, depth, false, _}) do
    {objs, [?{ | cur], depth + 1, false, false}
  end

  defp scan_char(?}, {objs, cur, depth, false, _}) do
    new_depth = depth - 1

    if new_depth <= 0 do
      object = [?} | cur] |> Enum.reverse() |> List.to_string()
      {[object | objs], [], 0, false, false}
    else
      {objs, [?} | cur], new_depth, false, false}
    end
  end

  # Between objects (depth 0): drop whitespace/newlines. Inside (depth > 0): keep.
  defp scan_char(char, {objs, cur, depth, false, _}) do
    if depth == 0,
      do: {objs, cur, depth, false, false},
      else: {objs, [char | cur], depth, false, false}
  end

  defp finish_objects({objs, _cur, _depth, _in_string, _escaped}), do: Enum.reverse(objs)

  # =============================================================================
  # Config + helpers
  # =============================================================================

  defp tool(config) do
    case Map.get(config, :tool) do
      t when t in @tools -> t
      _ -> "govulncheck"
    end
  end

  defp cmd(config, default) do
    case Map.get(config, :cmd) do
      cmd when is_binary(cmd) and cmd != "" -> cmd
      _ -> default
    end
  end

  defp args(config, default) do
    case Map.get(config, :args) do
      args when is_list(args) -> args
      _ -> default
    end
  end

  defp decode_json(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json_output}
    end
  end

  defp env_opt(config) do
    case Map.get(config, :env) do
      list when is_list(list) -> [env: normalize_env(list)]
      map when is_map(map) -> [env: normalize_env(Map.to_list(map))]
      _ -> []
    end
  end

  defp normalize_env(pairs) do
    Enum.map(pairs, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp numeric(n) when is_integer(n), do: n * 1.0
  defp numeric(n) when is_float(n), do: n
  defp numeric(_), do: nil

  defp truncate(output) when is_binary(output) do
    if String.length(output) > @output_limit do
      String.slice(output, 0, @output_limit) <> "…[truncated]"
    else
      output
    end
  end

  defp truncate(output), do: output
end
