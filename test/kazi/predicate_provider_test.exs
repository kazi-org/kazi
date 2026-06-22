defmodule Kazi.PredicateProviderTest do
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}

  # Test-only provider proving the @callback contract is usable. The real
  # providers (test-runner T0.5, http_probe T0.5b) live in lib/ in their own
  # tasks; nothing concrete belongs in lib/ for this contract.
  defmodule StubProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{kind: :tests} = predicate, context) do
      if context[:workspace] == predicate.config[:expect_workspace] do
        PredicateResult.pass(%{exit: 0, output: "all green"})
      else
        PredicateResult.fail(%{exit: 1, output: "wrong workspace"})
      end
    end

    def evaluate(%Predicate{}, _context), do: PredicateResult.error(%{reason: :unsupported_kind})
  end

  test "behaviour declares evaluate/2" do
    assert {:evaluate, 2} in Kazi.PredicateProvider.behaviour_info(:callbacks)
  end

  test "a conforming impl returns a PredicateResult" do
    predicate = Predicate.new(:unit, :tests, config: %{expect_workspace: "/ws"})
    result = StubProvider.evaluate(predicate, %{workspace: "/ws"})
    assert %PredicateResult{status: :pass, evidence: %{exit: 0}} = result
  end

  test "impl maps a non-matching context to a failing result with evidence" do
    predicate = Predicate.new(:unit, :tests, config: %{expect_workspace: "/ws"})
    result = StubProvider.evaluate(predicate, %{workspace: "/other"})
    assert result.status == :fail
    assert result.evidence.output == "wrong workspace"
  end

  test "impl signals an unevaluable predicate as :error, not :fail" do
    predicate = Predicate.new(:unknown, :mystery)
    assert %PredicateResult{status: :error} = StubProvider.evaluate(predicate, %{})
  end
end
