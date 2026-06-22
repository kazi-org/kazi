defmodule Kazi.ActionTest do
  use ExUnit.Case, async: true
  doctest Kazi.Action

  alias Kazi.Action

  # A tiny test-only implementation proving the behaviour contract is usable.
  # Concrete actions (integrate T0.10a, deploy T0.10b) live in lib/ in their own
  # tasks; this stub exists only to exercise the @callback here.
  defmodule StubAction do
    @behaviour Kazi.Action

    @impl true
    def execute(%Action{kind: :deploy} = action, context) do
      {:ok, %{deployed: action.params[:ref], workspace: context[:workspace]}}
    end

    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 7}}
    def execute(%Action{}, _context), do: {:error, :unsupported}
  end

  describe "new/2 (data type)" do
    test "builds an action with required kind and defaults" do
      a = Action.new(:dispatch_agent)
      assert a.kind == :dispatch_agent
      assert a.params == %{}
      assert a.metadata == %{}
    end

    test "carries params and metadata" do
      a = Action.new(:integrate, params: %{branch: "fix"}, metadata: %{iteration: 2})
      assert a.params == %{branch: "fix"}
      assert a.metadata == %{iteration: 2}
    end
  end

  describe "behaviour contract" do
    test "declares execute/2" do
      assert {:execute, 2} in Kazi.Action.behaviour_info(:callbacks)
    end

    test "a conforming impl can execute an action and return effects" do
      action = Action.new(:deploy, params: %{ref: "v1.2.3"})

      assert {:ok, %{deployed: "v1.2.3", workspace: "/tmp/ws"}} =
               StubAction.execute(action, %{workspace: "/tmp/ws"})
    end

    test "impl can signal failure for an unsupported action" do
      assert {:error, :unsupported} = StubAction.execute(Action.new(:unknown), %{})
    end
  end

  test "enforces kind on direct struct construction" do
    assert_raise ArgumentError, fn -> struct!(Action, params: %{}) end
  end
end
