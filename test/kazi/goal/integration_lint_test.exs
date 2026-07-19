defmodule Kazi.Goal.IntegrationLintTest do
  @moduledoc """
  T44.1 (ADR-0055): the advisory `[integration]` mode net `kazi lint` uses. It
  runs on the RAW decoded TOML, warns on an unknown `mode`, and stays silent for
  a known mode or an absent block.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.IntegrationLint

  test "an unknown mode yields a warning naming the bad value" do
    assert [%{mode: "rebase"}] =
             IntegrationLint.warnings(%{"integration" => %{"mode" => "rebase"}})
  end

  test "each known mode is clean" do
    for mode <- ~w(commit branch pr merge none) do
      assert [] = IntegrationLint.warnings(%{"integration" => %{"mode" => mode}})
    end
  end

  test "an absent [integration] block is clean" do
    assert [] = IntegrationLint.warnings(%{"id" => "g"})
  end

  test "an [integration] block with no mode is clean (loader defaults it to none)" do
    assert [] = IntegrationLint.warnings(%{"integration" => %{"base" => "main"}})
  end

  test "a non-string mode is warned (it is not a known mode)" do
    assert [%{mode: 3}] = IntegrationLint.warnings(%{"integration" => %{"mode" => 3}})
  end

  test "known_modes/0 lists the accepted set, sorted" do
    assert IntegrationLint.known_modes() == "branch, commit, merge, none, pr"
  end

  test "the known set matches the loader's" do
    loader_modes = Kazi.Goal.Loader.integration_modes() |> Map.keys() |> Enum.sort()

    for mode <- loader_modes do
      assert [] = IntegrationLint.warnings(%{"integration" => %{"mode" => mode}})
    end
  end
end
