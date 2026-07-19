defmodule Kazi.Goal.LoaderVisualJudgeTest do
  @moduledoc """
  T68.8 (#1522): the visual_judge predicate's load-time validation AND the
  loader<->runner registration parity. A provider registered in only one of the
  loader's `provider_kinds` table and the runtime's `provider_modules` dispatch
  table ships UNLOADABLE (the T49.10 landmine) — this pins that it is in both.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Runtime

  defp goal_map(pred_overrides) do
    predicate =
      Map.merge(
        %{
          "id" => "looks_right",
          "provider" => "visual_judge",
          "capture" => "now_screen",
          "rubric" => ["primary CTA visually dominant"],
          "model" => "claude-opus-4-8"
        },
        pred_overrides
      )

    %{
      "id" => "g",
      "capture" => [%{"name" => "now_screen", "launch_cmd" => "sh", "output" => "now_screen.png"}],
      "predicate" => [predicate]
    }
  end

  describe "loader <-> runner registration parity (T49.10 landmine)" do
    test ":visual_judge is registered in BOTH the loader kinds and the runtime modules" do
      loader_kinds = Loader.provider_kinds() |> Map.values() |> MapSet.new()
      runtime_kinds = Runtime.provider_modules() |> Map.keys() |> MapSet.new()

      assert MapSet.member?(loader_kinds, :visual_judge),
             "visual_judge missing from Kazi.Goal.Loader.provider_kinds/0 — unloadable"

      assert MapSet.member?(runtime_kinds, :visual_judge),
             "visual_judge missing from Kazi.Runtime.provider_modules/0 — loads but cannot dispatch"

      assert Runtime.provider_modules()[:visual_judge] == Kazi.Providers.VisualJudge
    end

    test "a well-formed visual_judge goal loads AND its kind is dispatchable" do
      assert {:ok, %Goal{predicates: [pred]}} = Loader.from_map(goal_map(%{}))
      assert pred.kind == :visual_judge

      # The runtime recognizes the kind (no {:unknown_provider_kinds, ...}).
      assert Map.has_key?(Runtime.provider_modules(), pred.kind)
    end
  end

  describe "load-time validation" do
    test "a visual_judge predicate naming no capture fails at load" do
      assert {:error, message} = Loader.from_map(goal_map(%{"capture" => nil}))
      assert message =~ "must name a capture"
    end

    test "a visual_judge predicate with an empty rubric fails at load" do
      assert {:error, message} = Loader.from_map(goal_map(%{"rubric" => []}))
      assert message =~ "non-empty `rubric`"
    end

    test "a visual_judge predicate with no pinned model fails at load" do
      assert {:error, message} = Loader.from_map(goal_map(%{"model" => nil}))
      assert message =~ "must pin a `model`"
    end

    test "the `input = \"capture:<name>\"` reference form is also accepted" do
      map = goal_map(%{"capture" => nil, "input" => "capture:now_screen"})
      assert {:ok, %Goal{predicates: [pred]}} = Loader.from_map(map)
      assert pred.kind == :visual_judge
    end
  end
end
