defmodule Kazi.Plan.RenderContractTest do
  @moduledoc """
  T73.6: `Kazi.Plan.Render.node/3` gains a "Contract" section, present only
  when the goal declares `[scope].contract`, carrying that file's raw content
  verbatim — the render extension to E72 T72.3's node.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader
  alias Kazi.Plan.Render
  alias Kazi.PredicateVector

  @fixture "test/fixtures/plan_render/contract_goal.goal.toml"
  @contract_path "test/fixtures/plan_render/contract_goal.contract.md"
  @root "lib/contracted"

  test "the rendered node contains the contract file's raw bytes" do
    {:ok, goal} = Loader.load(@fixture)
    rendered = Render.node(goal, @root, PredicateVector.new(%{}))

    assert rendered =~ "## Contract"
    assert rendered =~ "`#{@contract_path}`"
    assert rendered =~ File.read!(@contract_path)
  end

  test "a goal with no declared contract renders no Contract section" do
    {:ok, goal} = Loader.load("test/fixtures/plan_render/checkout_flow.goal.toml")
    rendered = Render.node(goal, "lib/checkout", PredicateVector.new(%{}))

    refute rendered =~ "## Contract"
  end
end
