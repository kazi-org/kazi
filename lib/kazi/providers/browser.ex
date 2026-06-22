defmodule Kazi.Providers.Browser do
  @moduledoc """
  The `:browser` predicate provider (T2.2): drives a real browser with Playwright
  and maps the result of a small interaction-and-assertion script to a
  `Kazi.PredicateResult` (ADR-0002, UC-012).

  This is the live-UI proof of Slice 2's creation mode (concept §2, §3): a
  predicate's truth is what a real browser *observes* after navigating to a URL
  and running the authored steps — an element is visible, a heading carries the
  expected text — not an agent's claim that the page works. Every assertion
  holding is a `:pass`; an assertion that does not hold is real failing work
  (`:fail`) with evidence of what was expected vs. found; an inability to drive
  the browser at all (Playwright missing, launch/timeout error, malformed config)
  is an `:error`, never a `:fail` — conflating the two would dispatch a fixer
  agent against an infra problem (`Kazi.PredicateResult`, ADR-0002).

  ## Architecture — Playwright via Port/subprocess

  kazi is Elixir; Playwright is JavaScript. Rather than embed a browser, the
  provider shells out (`System.cmd/3`, the same boundary `TestRunner` and
  `ProdLog` use) to a **Node runner script** shipped at
  `priv/browser/playwright_runner.js`. The provider serializes the predicate
  config (`url`, `steps`, `assertions`, …) to JSON, hands it to the runner as a
  single positional argument, and the runner prints one JSON result object to
  stdout:

      {"status":"pass"|"fail"|"error",
       "assertions":[{"type":..,"ok":true|false,"expected":..,"found":..}],
       "screenshot":"/path/to.png"|null,
       "url":"...", "error":"..."}

  The runner command is **injectable** (`config[:cmd]` / app config, defaulting to
  the real `node priv/browser/playwright_runner.js`) so tests substitute a STUB
  that returns canned JSON — exactly the seam `ProdLog` (the log-fetch `:cmd`),
  `TestRunner` (the test `:cmd`) and the claude adapter (the harness `:command`)
  already expose. No browser runs in `mix test`; CI stays Elixir-only.

  Real use requires the runtime deps the runner imports, installed once in the
  target workspace (or alongside this app):

      npm i playwright && npx playwright install chromium

  ## Config

  Read from `Kazi.Predicate.config`:

    * `:url`         — required. The page to open (string).
    * `:steps`       — optional. A list of interaction steps the runner replays
      before asserting, e.g. `[%{action: "click", selector: "#start"}]`. Handed
      verbatim to the runner; defaults to `[]`.
    * `:assertions`  — optional. A list of checks the runner evaluates, e.g.
      `[%{type: "visible", selector: "h1"}, %{type: "text", selector: "h1",
      contains: "Welcome"}]`. With none given, a page that loads passes (the
      probe only proves the page renders). Handed verbatim to the runner.
    * `:timeout_ms`  — optional. Per-operation timeout passed to the runner
      (default `30_000`).
    * `:screenshot`  — optional. Where the runner should write a screenshot
      (string path); recorded in evidence when the runner returns one.
    * `:cmd`         — optional. The runner executable (string). Defaults to the
      shipped `node`. Tests set this to a stub.
    * `:args`        — optional. Argument list for `:cmd`. Defaults to
      `[priv/browser/playwright_runner.js]`. Tests set this to point `:cmd` at a
      stub script.
    * `:env`         — optional. Extra environment as `{name, value}` pairs.

  The runner command may also be set in app config
  (`config :kazi, Kazi.Providers.Browser, cmd: ..., args: ...`); per-predicate
  config wins over app config, which wins over the shipped default.

  ## Context

  `context[:workspace]` is the directory the runner runs in (`cd:`), so a
  relative screenshot path or a workspace-local runner resolves against the same
  tree the harness edits. Defaults to the current directory when absent (mirrors
  `Kazi.Providers.TestRunner`).

  ## Evidence

  Every result carries the proof a fixer agent needs (ADR-0002): the resolved
  `:cmd`, `:args`, `:workspace`, the `:url` that was driven, and the per-assertion
  `:assertions` results (what was asserted, whether it held, expected vs. found);
  a `:screenshot` path when the runner produced one. On a provider error a
  `:reason` (and, where available, the runner's raw `:output`).
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  # The Node runner the provider ships and drives in production. Resolved against
  # the app's priv dir so it works from an escript / release as well as in-repo.
  @default_cmd "node"
  @default_runner "priv/browser/playwright_runner.js"
  @default_timeout_ms 30_000

  @impl true
  def evaluate(%Predicate{kind: :browser, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    with {:ok, url} <- fetch_url(config),
         {:ok, cmd, args} <- fetch_cmd(config),
         {:ok, payload} <- encode_payload(url, config) do
      drive(cmd, args, payload, url, workspace, config)
    else
      {:error, reason} ->
        PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # A browser predicate without a URL has nothing to drive: a config (:error)
  # problem, surfaced before we ever launch a browser.
  defp fetch_url(config) do
    case Map.get(config, :url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      nil -> {:error, :missing_url}
      other -> {:error, {:invalid_url, other}}
    end
  end

  # Resolve the runner command: per-predicate config wins, then app config, then
  # the shipped `node priv/browser/playwright_runner.js` default. A non-string
  # :cmd is a config error, not a crash.
  defp fetch_cmd(config) do
    app_config = Application.get_env(:kazi, __MODULE__, [])

    cmd = config[:cmd] || app_config[:cmd] || @default_cmd
    args = config[:args] || app_config[:args] || [default_runner_path()]

    cond do
      not (is_binary(cmd) and cmd != "") -> {:error, {:invalid_cmd, cmd}}
      not is_list(args) -> {:error, {:invalid_args, args}}
      true -> {:ok, cmd, args}
    end
  end

  # The shipped runner, resolved against the app's priv dir so it works from a
  # release/escript as well as in-repo. Falls back to the repo-relative path when
  # the app's priv dir is unavailable (e.g. running uncompiled).
  defp default_runner_path do
    case :code.priv_dir(:kazi) do
      {:error, _} -> @default_runner
      priv when is_list(priv) -> Path.join(to_string(priv), "browser/playwright_runner.js")
    end
  end

  # The instruction set handed to the runner as a JSON argument. Steps/assertions are
  # passed verbatim — the runner, not kazi, knows the Playwright vocabulary.
  defp encode_payload(url, config) do
    payload = %{
      url: url,
      steps: Map.get(config, :steps, []),
      assertions: Map.get(config, :assertions, []),
      timeout_ms: Map.get(config, :timeout_ms, @default_timeout_ms),
      screenshot: Map.get(config, :screenshot)
    }

    case Jason.encode(payload) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_config, Exception.message(reason)}}
    end
  end

  # Run the Node runner in the workspace, feeding the JSON payload on stdin and
  # capturing stdout (the JSON result) + stderr together. System.cmd/3 raises
  # only when the executable cannot be found or the cwd is invalid — both are
  # infra problems, so we map them to :error rather than letting the provider
  # crash (mirrors TestRunner/ProdLog).
  defp drive(cmd, args, payload, url, workspace, config) do
    opts = [cd: workspace, stderr_to_stdout: true]
    opts = if env = config[:env], do: Keyword.put(opts, :env, env), else: opts

    # The runner reads the JSON payload as the last positional argument so the
    # seam is identical for a real `node` and a one-line stub (no stdin plumbing).
    case System.cmd(cmd, args ++ [payload], opts) do
      {output, 0} ->
        interpret(output, cmd, args, url, workspace)

      {output, exit_code} ->
        # A non-zero runner exit is the browser failing to even produce a verdict
        # (launch failure, crash): infra, not a claim about the UI.
        PredicateResult.error(%{
          reason: {:runner_failed, exit_code},
          cmd: cmd,
          args: args,
          url: url,
          workspace: workspace,
          output: output
        })
    end
  rescue
    error in [ErlangError, File.Error] ->
      PredicateResult.error(%{
        reason: {:cmd_unrunnable, Exception.message(error)},
        cmd: cmd,
        args: args,
        url: url,
        workspace: workspace
      })
  end

  # Parse the runner's JSON verdict and map it to the contract. A runner that
  # ran but emitted unparseable output is an :error (we cannot make a claim
  # about the UI), not a :fail.
  defp interpret(output, cmd, args, url, workspace) do
    case decode_result(output) do
      {:ok, %{"status" => status} = result} when status in ["pass", "fail", "error"] ->
        evidence =
          %{
            cmd: cmd,
            args: args,
            url: url,
            workspace: workspace,
            assertions: Map.get(result, "assertions", []),
            screenshot: Map.get(result, "screenshot")
          }
          |> maybe_put_error(result)

        build(status, evidence)

      {:ok, other} ->
        PredicateResult.error(%{
          reason: {:invalid_runner_result, other},
          cmd: cmd,
          args: args,
          url: url,
          workspace: workspace
        })

      {:error, reason} ->
        PredicateResult.error(%{
          reason: {:unparseable_runner_output, reason},
          cmd: cmd,
          args: args,
          url: url,
          workspace: workspace,
          output: output
        })
    end
  end

  # The runner may print diagnostics before the JSON verdict; take the last
  # JSON object line so leading log noise does not defeat parsing.
  defp decode_result(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value({:error, :no_json}, fn line ->
      case Jason.decode(line) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> nil
      end
    end)
  end

  defp maybe_put_error(evidence, %{"error" => error}) when not is_nil(error),
    do: Map.put(evidence, :error, error)

  defp maybe_put_error(evidence, _), do: evidence

  defp build("pass", evidence), do: PredicateResult.pass(evidence)
  defp build("fail", evidence), do: PredicateResult.fail(evidence)
  # An "error" verdict from the runner is the runner reporting it could not
  # evaluate (e.g. navigation timeout) — infra, not failing UI work.
  defp build("error", evidence),
    do:
      PredicateResult.error(
        Map.put(evidence, :reason, {:runner_reported_error, evidence[:error]})
      )
end
