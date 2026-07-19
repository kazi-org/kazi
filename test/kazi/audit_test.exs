defmodule Kazi.AuditTest do
  @moduledoc """
  T68.9 (#1501): the audit orchestration ties sampling + scoring + recording.
  HERMETIC: the SQLite Sandbox stands in for the read-model; the mutation and
  re-evaluation are an injected function (no git, no harness).
  """
  use ExUnit.Case, async: false

  alias Kazi.{Audit, PredicateResult, PredicateVector, ReadModel, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp vector(pairs) do
    PredicateVector.new(Map.new(pairs, fn {id, s} -> {id, result(s)} end))
  end

  defp result(:pass), do: PredicateResult.pass()
  defp result(:fail), do: PredicateResult.fail()

  test "sampled audit records a score per goal" do
    baseline = vector(a: :pass, b: :pass, c: :pass)
    reevaluate = fn -> vector(a: :fail, b: :pass, c: :fail) end

    assert {:sampled, summary} =
             Audit.run("goal-run", baseline, reevaluate: reevaluate, sample_rate: 1.0)

    assert summary.tested == 3
    assert summary.constrained == 2
    assert summary.survivors == [:b]

    row = ReadModel.latest_predicate_audit("goal-run")
    assert row.tested == 3
    assert row.constrained == 2
    assert ReadModel.audit_survivors(row) == ["b"]
  end

  test "the sampling gate can skip an audit (nothing recorded)" do
    baseline = vector(a: :pass)
    reevaluate = fn -> flunk("reevaluate must not run when sampling declines") end

    assert Audit.run("goal-skip", baseline, reevaluate: reevaluate, sample_rate: 0.0) == :skipped
    assert ReadModel.latest_predicate_audit("goal-skip") == nil
  end

  test "record?: false computes the score without persisting it" do
    baseline = vector(a: :pass, b: :pass)
    reevaluate = fn -> vector(a: :fail, b: :fail) end

    assert {:sampled, %{sensitivity: 1.0}} =
             Audit.run("goal-norecord", baseline,
               reevaluate: reevaluate,
               sample_rate: 1.0,
               record?: false
             )

    assert ReadModel.latest_predicate_audit("goal-norecord") == nil
  end
end
