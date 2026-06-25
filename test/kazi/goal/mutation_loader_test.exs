defmodule Kazi.Goal.MutationLoaderTest do
  @moduledoc """
  T32.8 (ADR-0043): the loader maps `provider = "mutation"` to the `:mutation`
  kind and VALIDATES its threshold + score config, so a mis-declared mutation gate
  fails loudly at load. The headline rule: a mutation threshold is NEVER 100% —
  a perfect score is an unreachable, gameable target (equivalent mutants).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "mutation"}, predicate_toml)]
    })
  end

  @ok %{
    "cmd" => "mix",
    "args" => ["muzak", "--diff", "--format", "json"],
    "threshold" => 0.8,
    "killed_path" => "$.summary.killed",
    "survived_path" => "$.summary.survived"
  }

  test "a well-formed mutation predicate loads" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :mutation, config: config}]}} = load(@ok)
    assert config.threshold == 0.8
  end

  test "a score_path (without counts) loads" do
    config = %{"cmd" => "mix", "threshold" => 0.7, "score_path" => "$.mutation_score"}
    assert {:ok, _} = load(config)
  end

  test "a threshold of 1.0 (100%) is REJECTED at load" do
    assert {:error, msg} = load(%{@ok | "threshold" => 1.0})
    assert msg =~ "NEVER 100%"
  end

  test "a threshold above 1.0 is rejected at load" do
    assert {:error, msg} = load(%{@ok | "threshold" => 1.5})
    assert msg =~ "< 1.0"
  end

  test "a missing threshold is a load error" do
    assert {:error, msg} = load(Map.delete(@ok, "threshold"))
    assert msg =~ "threshold"
  end

  test "no way to read the score is a load error" do
    config = %{"cmd" => "mix", "threshold" => 0.8}
    assert {:error, msg} = load(config)
    assert msg =~ "score_path"
  end

  test "killed_path without survived_path is a load error" do
    config = %{"cmd" => "mix", "threshold" => 0.8, "killed_path" => "$.k"}
    assert {:error, _msg} = load(config)
  end
end
