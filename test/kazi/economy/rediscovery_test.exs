defmodule Kazi.Economy.RediscoveryTest do
  @moduledoc """
  Tier 1 -- the pure rediscovery-pressure fold (T48.10, ADR-0058 decision 3).
  Drives `Kazi.Economy.Rediscovery` with fixture iterations: a category whose
  tool calls persist past the first (cold) dispatch ranks as a candidate; an
  absent tool-use stream reports `:unknown`, never a fabricated empty ranking;
  a genuinely measured zero-rediscovery run reports `:ranked` with NO
  candidates (a different claim from `:unknown`).
  """
  use ExUnit.Case, async: true

  alias Kazi.Economy.Rediscovery

  defp iteration(tools) when is_map(tools), do: %{tools: tools}
  defp iteration(), do: %{tools: %{}}

  describe "candidates/1 -- ranked signal" do
    test "ranks a category whose calls recur across dispatches above a one-off spike" do
      iterations = [
        # baseline (cold) dispatch.
        iteration(%{tool_calls: 12, file_reads: 8, search_calls: 3, graph_calls: 1}),
        # search_calls recurs on every later dispatch -- persistent pressure.
        iteration(%{tool_calls: 5, file_reads: 0, search_calls: 4, graph_calls: 0}),
        iteration(%{tool_calls: 4, file_reads: 0, search_calls: 3, graph_calls: 0}),
        # file_reads spikes ONCE then falls to zero -- a one-off, not persistent.
        iteration(%{tool_calls: 6, file_reads: 6, search_calls: 0, graph_calls: 0})
      ]

      report = Rediscovery.candidates(iterations)

      assert %{status: :ranked, candidates: candidates} = report
      categories = Enum.map(candidates, & &1.category)
      # Both categories recurred at least once, so both are candidates...
      assert :search_calls in categories
      assert :file_reads in categories
      # ...but search_calls (persists on 2 of 3 later dispatches) outranks
      # file_reads (persists on only 1 of 3), even though file_reads' one spike
      # (6) is bigger than any single search_calls count.
      assert [top | _] = candidates
      assert top.category == :search_calls
      assert top.recurring_calls == 7
      assert top.recurring_dispatches == 2
      assert top.dispatches_compared == 3
      assert top.total_calls == 10
      assert top.label =~ "retrieval-cache candidate"

      file_reads = Enum.find(candidates, &(&1.category == :file_reads))
      assert file_reads.recurring_calls == 6
      assert file_reads.recurring_dispatches == 1
      assert file_reads.label =~ "orientation-pack candidate"

      # graph_calls never recurred past the baseline -- not a candidate at all.
      refute Enum.any?(candidates, &(&1.category == :graph_calls))
    end

    test "a goal whose tool signal genuinely stops recurring reports :ranked with NO candidates" do
      iterations = [
        iteration(%{tool_calls: 10, file_reads: 7, search_calls: 2, graph_calls: 1}),
        iteration(%{tool_calls: 1, file_reads: 0, search_calls: 0, graph_calls: 0}),
        iteration(%{tool_calls: 1, file_reads: 0, search_calls: 0, graph_calls: 0})
      ]

      assert Rediscovery.candidates(iterations) == %{status: :ranked, candidates: []}
    end

    test "accepts string-keyed tools maps and atom-or-string iteration wrappers" do
      iterations = [
        %{"tools" => %{"file_reads" => 5, "search_calls" => 1, "graph_calls" => 0}},
        %{"tools" => %{"file_reads" => 4, "search_calls" => 1, "graph_calls" => 0}}
      ]

      assert %{status: :ranked, candidates: [top | _]} = Rediscovery.candidates(iterations)
      assert top.category == :file_reads
      assert top.recurring_calls == 4
    end
  end

  describe "candidates/1 -- honest-unknown" do
    test "no iterations recorded at all is :unknown, not an empty ranking" do
      assert %{status: :unknown, reason: reason} = Rediscovery.candidates([])
      assert reason =~ "no iterations recorded"
    end

    test "iterations recorded but with NO tool-use stream is :unknown (absent != zero)" do
      iterations = [iteration(), iteration(), iteration()]

      assert %{status: :unknown, reason: reason} = Rediscovery.candidates(iterations)
      assert reason =~ "no tool-use stream recorded"
    end

    test "a single tool-bearing dispatch is :unknown (needs >= 2 to compare)" do
      iterations = [
        iteration(),
        iteration(%{tool_calls: 3, file_reads: 2, search_calls: 1, graph_calls: 0})
      ]

      assert %{status: :unknown, reason: reason} = Rediscovery.candidates(iterations)
      assert reason =~ "only one tool-bearing dispatch"
    end
  end

  describe "to_json/1" do
    test "an unknown report carries only status/reason -- never a candidates key" do
      report = %{status: :unknown, reason: "no tool-use stream recorded for any iteration"}
      json = Rediscovery.to_json(report)

      assert json == %{
               "status" => "unknown",
               "reason" => "no tool-use stream recorded for any iteration"
             }

      refute Map.has_key?(json, "candidates")
    end

    test "a ranked report renders candidates as JSON-safe maps with string categories" do
      iterations = [
        iteration(%{file_reads: 8, search_calls: 3, graph_calls: 0}),
        iteration(%{file_reads: 0, search_calls: 3, graph_calls: 0}),
        iteration(%{file_reads: 0, search_calls: 2, graph_calls: 0})
      ]

      report = Rediscovery.candidates(iterations)
      json = Rediscovery.to_json(report)

      assert json["status"] == "ranked"
      assert [candidate] = json["candidates"]
      assert candidate["category"] == "search_calls"
      assert candidate["recurring_calls"] == 5
      assert is_binary(candidate["label"])
    end

    test "a genuinely-empty ranked report renders an empty candidates list" do
      json = Rediscovery.to_json(%{status: :ranked, candidates: []})
      assert json == %{"status" => "ranked", "candidates" => []}
    end
  end
end
