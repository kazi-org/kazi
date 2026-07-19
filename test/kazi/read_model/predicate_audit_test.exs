defmodule Kazi.ReadModel.PredicateAuditTest do
  @moduledoc """
  T68.9 (#1501): the `predicate_audits` projection records the latest sampled
  predicate mutation audit per goal (last-write-wins), honest-unknown on an
  empty audit. HERMETIC: the SQLite Sandbox stands in for the shared read-model.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Kazi.ReadModel
  alias Kazi.ReadModel.PredicateAudit
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp summary(overrides) do
    Map.merge(
      %{tested: 3, constrained: 2, survived: 1, sensitivity: 2 / 3, survivors: [:b]},
      Map.new(overrides)
    )
  end

  test "records and reads back the latest audit score for a goal" do
    assert {:ok, _} = ReadModel.record_predicate_audit("goal-audit", summary([]))

    row = ReadModel.latest_predicate_audit("goal-audit")
    assert row.tested == 3
    assert row.constrained == 2
    assert row.survived == 1
    assert_in_delta row.sensitivity, 2 / 3, 1.0e-9
    assert ReadModel.audit_survivors(row) == ["b"]
    assert %DateTime{} = row.sampled_at
  end

  test "a re-audit overwrites the goal's prior row (last-write-wins)" do
    assert {:ok, _} =
             ReadModel.record_predicate_audit(
               "goal-reaudit",
               summary(
                 tested: 3,
                 constrained: 1,
                 survived: 2,
                 sensitivity: 1 / 3,
                 survivors: [:a, :c]
               )
             )

    assert {:ok, _} =
             ReadModel.record_predicate_audit(
               "goal-reaudit",
               summary(tested: 4, constrained: 4, survived: 0, sensitivity: 1.0, survivors: [])
             )

    row = ReadModel.latest_predicate_audit("goal-reaudit")
    assert row.tested == 4
    assert row.constrained == 4
    assert row.sensitivity == 1.0
    assert ReadModel.audit_survivors(row) == []

    # Exactly one row for the goal — the upsert did not accumulate.
    assert Repo.aggregate(from(a in PredicateAudit, where: a.goal_ref == "goal-reaudit"), :count) ==
             1
  end

  test "an audit with nothing to test records NULL sensitivity (honest-unknown)" do
    assert {:ok, _} =
             ReadModel.record_predicate_audit(
               "goal-empty",
               summary(tested: 0, constrained: 0, survived: 0, sensitivity: nil, survivors: [])
             )

    row = ReadModel.latest_predicate_audit("goal-empty")
    assert row.tested == 0
    assert row.sensitivity == nil
  end

  test "an un-audited goal reads back nil" do
    assert ReadModel.latest_predicate_audit("never-audited") == nil
  end
end
