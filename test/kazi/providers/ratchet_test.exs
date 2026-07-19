defmodule Kazi.Providers.RatchetTest do
  @moduledoc """
  The `:ratchet` provider maps the shared machinery onto an envelope-v2
  `PredicateResult` — `score = signal`, a `direction`, the comparison as evidence
  (T32.3, ADR-0041). Tier 2: real commands in a temp workspace.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Ratchet
  alias Kazi.Ratchet.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_ratchet_prov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp const(n), do: %{"cmd" => "sh", "args" => ["-c", "printf '%s' '#{n}'"]}

  defp evaluate(config, ws) do
    Ratchet.evaluate(Predicate.new(:check, :ratchet, config: config), %{workspace: ws})
  end

  test "implements the PredicateProvider behaviour" do
    behaviours = Ratchet.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "string-keyed goal-file config (the loader shape)" do
    test "coverage passes when the signal improves, reporting score = signal", %{workspace: ws} do
      config = %{
        metric: const("85"),
        baseline: 80.0,
        direction: "higher_better",
        allowed_regression: 0.0
      }

      result = evaluate(config, ws)
      assert %PredicateResult{status: :pass, score: 85.0, direction: :higher_better} = result
      assert result.evidence.baseline == 80.0
      assert result.evidence.signal == 85.0
    end

    test "coverage fails on a regression beyond allowed_regression", %{workspace: ws} do
      config = %{
        metric: const("78"),
        baseline: 80.0,
        direction: "higher_better",
        allowed_regression: 1.0
      }

      result = evaluate(config, ws)
      assert result.status == :fail
      assert result.score == 78.0
      assert result.evidence.regression == 2.0
    end

    test "the SAME provider services a size (lower_better) example", %{workspace: ws} do
      config = %{metric: const("1100"), baseline: 1000.0, direction: "lower_better"}
      result = evaluate(config, ws)
      assert %PredicateResult{status: :fail, score: 1100.0, direction: :lower_better} = result
      assert result.evidence.regression == 100.0
    end
  end

  describe "stored baseline (envelope-v2 gradient + persistence)" do
    test "stores the new baseline and reports the score across runs", %{workspace: ws} do
      config = %{metric: const("80"), baseline: "stored", direction: "higher_better"}

      first = evaluate(config, ws)
      assert first.status == :pass
      assert first.score == 80.0
      assert first.evidence.baseline_source == :seed
      assert Store.read(Path.join(ws, ".kazi"), :check) == {:ok, 80.0}

      improved = evaluate(%{config | metric: const("90")}, ws)
      assert improved.status == :pass
      assert improved.score == 90.0
      assert improved.evidence.stored == true
      assert Store.read(Path.join(ws, ".kazi"), :check) == {:ok, 90.0}
    end
  end

  describe "a broken metric is :error, never a false pass" do
    test "a missing metric binary surfaces :error with a reason", %{workspace: ws} do
      config = %{
        metric: %{"cmd" => "definitely-not-a-real-binary-xyz"},
        baseline: 80.0,
        direction: "higher_better"
      }

      result = evaluate(config, ws)
      assert result.status == :error
      assert {:metric_unrunnable, _} = result.evidence.reason
    end
  end

  test "an unsupported kind is an :error (defensive)" do
    result = Ratchet.evaluate(Predicate.new(:x, :tests, config: %{}), %{})
    assert %PredicateResult{status: :error} = result
    assert {:unsupported_kind, :tests} = result.evidence.reason
  end
end
