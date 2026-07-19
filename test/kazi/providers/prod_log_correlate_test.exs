defmodule Kazi.Providers.ProdLogCorrelateTest do
  @moduledoc """
  T41.5 (ADR-0051 decision 4): the opt-in `correlate: {route, window}` trust-check.
  Same Tier-2 fixture-log seam as ProdLogTest — the log source is a real `cat` of a
  temp file, so the provider runs its real correlation over real process output.

  The three acc clauses:

    * a `:pass` whose correlated route has an in-window prod error carries
      `correlated_prod_error: true` — the verdict STAYS `:pass` (the flag
      downgrades trust in the green, ADR-0051 d4: "rather than silently trusting
      the green"), only the evidence gains the flag;
    * a clean correlated route's `:pass` is unaffected (`false` flag, still pass);
    * NO `correlate` config produces evidence byte-identical to the base provider
      — the regression guard.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.ProdLog

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_prod_log_corr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp log_source(workspace, log_text, extra) do
    path = Path.join(workspace, "logs_#{System.unique_integer([:positive])}.txt")
    File.write!(path, log_text)
    Map.merge(%{cmd: "cat", args: [path]}, extra)
  end

  defp evaluate(workspace, log_text, extra) do
    config = log_source(workspace, log_text, extra)
    ProdLog.evaluate(Predicate.new(:prod, :prod_log, config: config), %{workspace: workspace})
  end

  # A clean base window (no panic, 5xx within tolerance) so the BASE verdict is
  # :pass — correlation is a trust-check ON a green, so a green is the precondition
  # this exercises. `max_5xx: 100` keeps the base green even when the log carries a
  # correlated 5xx, isolating the flag from the base verdict.
  @correlate %{correlate: %{"route" => "/checkout", "window" => 60}, max_5xx: 100}

  test "a :pass whose route has an in-window prod error carries the flag, still passes",
       %{workspace: ws} do
    logs = """
    2026-06-21T10:00:00Z GET /healthz status: 200
    2026-06-21T10:00:01Z GET /checkout status: 200
    2026-06-21T10:00:02Z POST /checkout status: 503
    """

    result = evaluate(ws, logs, @correlate)

    # Verdict unchanged — the flag downgrades TRUST, not the verdict.
    assert %PredicateResult{status: :pass} = result
    assert result.evidence.correlated_prod_error == true
    assert result.evidence.correlate == %{route: "/checkout", window: 60}
    assert Enum.any?(result.evidence.correlated_lines, &String.contains?(&1, "/checkout"))
    assert Enum.all?(result.evidence.correlated_lines, &String.contains?(&1, "503"))
  end

  test "a panic on the correlated route is flagged, and the base already fails on it",
       %{workspace: ws} do
    logs = """
    2026-06-21T10:00:00Z GET /checkout status: 200
    2026-06-21T10:00:01Z panic: nil deref serving /checkout
    """

    result =
      evaluate(ws, logs, %{correlate: %{"route" => "/checkout", "window" => 60}, max_5xx: 100})

    # A panic fails the BASE check regardless of max_5xx (any panic fails), so a
    # panic can never coexist with a base :pass — correlation is verdict-independent
    # evidence, and here it independently confirms the failure is on the named route.
    assert %PredicateResult{status: :fail} = result
    assert result.evidence.correlated_prod_error == true
  end

  test "a clean correlated route's :pass is unaffected (flag false, still pass)",
       %{workspace: ws} do
    # The 5xx is on a DIFFERENT route, so the /checkout correlation is clean.
    logs = """
    2026-06-21T10:00:00Z GET /checkout status: 200
    2026-06-21T10:00:01Z POST /admin status: 500
    """

    result = evaluate(ws, logs, @correlate)

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.correlated_prod_error == false
    assert result.evidence.correlated_lines == []
  end

  test "correlate reads an atom-keyed config too (programmatic construction)",
       %{workspace: ws} do
    logs = "2026-06-21T10:00:00Z GET /checkout status: 503\n"

    result = evaluate(ws, logs, %{correlate: %{route: "/checkout", window: 60}, max_5xx: 100})

    assert result.evidence.correlated_prod_error == true
    assert result.evidence.correlate == %{route: "/checkout", window: 60}
  end

  describe "regression guard — no correlate config is byte-identical" do
    test "evidence has EXACTLY the base keys, none of the correlate keys",
         %{workspace: ws} do
      logs = """
      2026-06-21T10:00:00Z GET /checkout status: 200
      2026-06-21T10:00:01Z POST /checkout status: 503
      """

      with_correlate = evaluate(ws, logs, %{max_5xx: 100, correlate: %{"route" => "/checkout"}})
      without = evaluate(ws, logs, %{max_5xx: 100})

      base_keys = MapSet.new(Map.keys(without.evidence))

      # The base evidence carries none of the correlation keys — a goal that never
      # named correlate is untouched (the acc's regression guard).
      refute MapSet.member?(base_keys, :correlate)
      refute MapSet.member?(base_keys, :correlated_prod_error)
      refute MapSet.member?(base_keys, :correlated_lines)

      # And correlation is purely additive: it adds exactly those three keys.
      added = MapSet.difference(MapSet.new(Map.keys(with_correlate.evidence)), base_keys)
      assert added == MapSet.new([:correlate, :correlated_prod_error, :correlated_lines])
    end
  end
end
