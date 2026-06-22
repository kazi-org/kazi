defmodule Kazi.Providers.ProdLogTest do
  # Tier 2: real boundary. The log source is the genuine System.cmd seam the
  # provider uses in production; tests inject a stub command (`cat` of a temp
  # file holding canned log output) so the provider runs its real classification
  # over real process output and maps it to the contract (T1.6, UC-021).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.ProdLog

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_prod_log_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Write `log_text` to a file in the workspace and return a config whose log
  # source is `cat <file>` — a real command emitting the canned log output.
  defp log_source(workspace, log_text, extra \\ %{}) do
    path = Path.join(workspace, "logs_#{System.unique_integer([:positive])}.txt")
    File.write!(path, log_text)
    Map.merge(%{cmd: "cat", args: [path]}, extra)
  end

  defp predicate(config), do: Predicate.new(:prod, :prod_log, config: config)

  defp evaluate(workspace, log_text, extra \\ %{}) do
    config = log_source(workspace, log_text, extra)
    ProdLog.evaluate(predicate(config), %{workspace: workspace})
  end

  test "implements the PredicateProvider behaviour" do
    behaviours = ProdLog.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  test "clean logs over the window -> :pass with zero counts in evidence", %{workspace: ws} do
    clean = """
    2026-06-21T10:00:00Z GET /healthz status: 200 ok
    2026-06-21T10:00:01Z GET / status: 304
    2026-06-21T10:00:02Z POST /api status=201
    """

    result = evaluate(ws, clean, %{window_minutes: 30})

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.server_error_count == 0
    assert result.evidence.panic_count == 0
    assert result.evidence.window_minutes == 30
    assert result.evidence.max_5xx == 0
    assert result.evidence.matched_lines == []
  end

  test "5xx over threshold -> :fail (not :error) with count + sample lines", %{workspace: ws} do
    noisy = """
    2026-06-21T10:00:00Z GET /a status: 200
    2026-06-21T10:00:01Z GET /b status: 500
    2026-06-21T10:00:02Z GET /c status: 503
    """

    # default max_5xx is 0, so two 5xx lines exceed the threshold.
    result = evaluate(ws, noisy)

    assert result.status == :fail
    assert result.evidence.server_error_count == 2
    assert result.evidence.panic_count == 0
    assert Enum.any?(result.evidence.matched_lines, &(&1 =~ "status: 500"))
    assert Enum.any?(result.evidence.matched_lines, &(&1 =~ "status: 503"))
  end

  test "5xx at or under max_5xx threshold -> :pass", %{workspace: ws} do
    one_5xx = """
    2026-06-21T10:00:00Z GET /a status: 200
    2026-06-21T10:00:01Z GET /b status: 502
    """

    result = evaluate(ws, one_5xx, %{max_5xx: 1})

    assert result.status == :pass
    assert result.evidence.server_error_count == 1
    assert result.evidence.max_5xx == 1
  end

  test "a panic line -> :fail regardless of 5xx threshold", %{workspace: ws} do
    paniced = """
    2026-06-21T10:00:00Z GET /a status: 200
    2026-06-21T10:00:01Z panic: runtime error: invalid memory address
    goroutine 1 [running]:
    """

    # generous 5xx allowance — the panic alone must fail it.
    result = evaluate(ws, paniced, %{max_5xx: 100})

    assert result.status == :fail
    assert result.evidence.panic_count == 1
    assert Enum.any?(result.evidence.matched_lines, &(&1 =~ "panic"))
  end

  test "empty log output (quiet window) -> :pass with zero counts", %{workspace: ws} do
    result = evaluate(ws, "")

    assert result.status == :pass
    assert result.evidence.server_error_count == 0
    assert result.evidence.panic_count == 0
    assert result.evidence.matched_lines == []
  end

  test "custom panic_regex is honoured", %{workspace: ws} do
    logs = """
    2026-06-21T10:00:00Z FATAL worker crashed unexpectedly
    2026-06-21T10:00:01Z GET /a status: 200
    """

    result = evaluate(ws, logs, %{panic_regex: "FATAL"})

    assert result.status == :fail
    assert result.evidence.panic_count == 1
  end

  test "matched-line sample is bounded", %{workspace: ws} do
    many = Enum.map_join(1..50, "\n", fn i -> "line #{i} status: 500" end)

    result = evaluate(ws, many, %{max_5xx: 0})

    assert result.status == :fail
    assert result.evidence.server_error_count == 50
    assert length(result.evidence.matched_lines) <= 20
  end

  test "the log-fetch command runs in the target workspace", %{workspace: ws} do
    File.write!(Path.join(ws, "prod.log"), "GET /healthz status: 200 ok\n")
    # relative path resolves only if the command ran with cwd == workspace.
    result =
      ProdLog.evaluate(predicate(%{cmd: "cat", args: ["prod.log"]}), %{workspace: ws})

    assert result.status == :pass
    assert result.evidence.workspace == ws
  end

  test "log-fetch command not found -> :error, no crash", %{workspace: ws} do
    config = %{cmd: "kazi_no_such_log_tool_#{System.unique_integer([:positive])}"}
    result = ProdLog.evaluate(predicate(config), %{workspace: ws})

    assert %PredicateResult{status: :error} = result
    assert match?({:cmd_unrunnable, _}, result.evidence.reason)
  end

  test "log-fetch command failing (non-zero exit) -> :error, not :fail", %{workspace: ws} do
    # `cat` of a missing file exits non-zero: a query/infra problem, not a claim
    # about production logs.
    config = %{cmd: "cat", args: [Path.join(ws, "does_not_exist.log")]}
    result = ProdLog.evaluate(predicate(config), %{workspace: ws})

    assert result.status == :error
    assert match?({:query_failed, _}, result.evidence.reason)
  end

  test "absent :cmd in config -> :error, not a crash", %{workspace: ws} do
    result = ProdLog.evaluate(predicate(%{}), %{workspace: ws})

    assert result.status == :error
    assert result.evidence.reason == :missing_cmd
  end

  test "invalid regex in config -> :error, not a crash", %{workspace: ws} do
    config = log_source(ws, "", %{panic_regex: "("})
    result = ProdLog.evaluate(predicate(config), %{workspace: ws})

    assert result.status == :error
    assert match?({:invalid_regex, :panic_regex, _}, result.evidence.reason)
  end

  test "non-:prod_log predicate kind -> :error" do
    result = ProdLog.evaluate(Predicate.new(:t, :tests), %{})
    assert %PredicateResult{status: :error} = result
    assert match?({:unsupported_kind, :tests}, result.evidence.reason)
  end

  test "defaults workspace to cwd when context omits it", %{workspace: ws} do
    # A clean absolute-path source works without a context workspace.
    config = log_source(ws, "GET /healthz status: 200\n")
    result = ProdLog.evaluate(predicate(config), %{})

    assert result.status == :pass
    assert result.evidence.workspace == File.cwd!()
  end
end
