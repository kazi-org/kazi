defmodule Kazi.Economy.KPIsTest do
  @moduledoc """
  Tier 1 — the pure run-end economy-KPI fold (T34.6, ADR-0046 §5). Drives
  `Kazi.Economy.KPIs` with fixture runs: KPIs compute from the per-iteration
  envelopes; an unreported field yields an UNAVAILABLE (`nil`) KPI, never zero;
  the breakdown groups by harness/model/context-tier; and the benchmark consumes
  the same `economy` object a run emits.
  """
  use ExUnit.Case, async: true

  alias Kazi.Economy.KPIs

  # A two-iteration converged run: a cold first dispatch (cache miss, heavy
  # re-discovery) then a warm second (orientation cache HIT, fewer tool calls).
  defp converged_run(overrides \\ %{}) do
    base = %{
      harness: "claude",
      model: "haiku",
      context_tier: "C",
      status: "converged",
      converged_predicates: 2,
      iteration_count: 2,
      usage: %{cost_usd: 0.02, cached_input_tokens: 18_000},
      iterations: [
        %{
          converged: false,
          observed_at: ~U[2026-06-25 10:00:00.000000Z],
          context: %{
            "orientation_cache" => "miss",
            "retrieval_cache" => "disabled",
            "orientation_tokens" => 400,
            "evidence_tokens" => 50,
            "retrieval_tokens" => 0
          },
          tools: %{"tool_calls" => 9, "file_reads" => 6, "search_calls" => 3, "graph_calls" => 1}
        },
        %{
          converged: true,
          observed_at: ~U[2026-06-25 10:00:20.000000Z],
          context: %{
            "orientation_cache" => "hit",
            "retrieval_cache" => "disabled",
            "orientation_tokens" => 400,
            "evidence_tokens" => 40,
            "retrieval_tokens" => 0
          },
          tools: %{"tool_calls" => 3, "file_reads" => 1, "search_calls" => 1, "graph_calls" => 0}
        }
      ]
    }

    Map.merge(base, overrides)
  end

  describe "compute/1 — single run KPIs" do
    test "derives the cost/wall-clock per-converged-predicate, iters-to-convergence, and avoided counters" do
      kpis = KPIs.compute(converged_run())

      assert kpis.status == "converged"
      assert kpis.stuck == false
      assert kpis.converged_predicates == 2
      assert kpis.iterations == 2
      # convergence is the 2nd (1-based) observation.
      assert kpis.iterations_to_convergence == 2

      assert kpis.cost_usd == 0.02
      # 0.02 / 2 converged predicates.
      assert kpis.cost_per_converged_predicate == 0.01

      # T34.8: the run-aggregate token total surfaces on the economy object (here
      # only cached_input was reported ⇒ that IS the total) — never "tokens: 0".
      assert kpis.tokens == 18_000

      # 20s span between the two observation timestamps.
      assert kpis.wall_clock_s == 20.0
      assert kpis.wall_clock_per_converged_predicate == 10.0

      # The orientation prefix HIT on iteration 2 served its 400 tokens from cache
      # instead of fresh (retrieval was disabled ⇒ contributes nothing).
      assert kpis.fresh_input_tokens_avoided == 400

      # Cold baseline re-discovery = 6+3+1 = 10; warm iteration did 1+1+0 = 2 ⇒ 8 avoided.
      assert kpis.rediscovery_tool_calls_avoided == 8
    end

    test "a stuck run reports stuck=true and nil iterations-to-convergence (never the total)" do
      run = converged_run(%{status: "stuck", converged_predicates: 1})
      run = %{run | iterations: Enum.map(run.iterations, &Map.put(&1, :converged, false))}

      kpis = KPIs.compute(run)

      assert kpis.stuck == true
      assert kpis.iterations_to_convergence == nil
      # cost/converged-predicate still computes against the 1 predicate that passed.
      assert kpis.cost_per_converged_predicate == 0.02
    end
  end

  describe "honest-unknown — an unreported field yields an UNAVAILABLE KPI, never zero" do
    test "no cost reported ⇒ cost KPIs are nil (not 0.0)" do
      run = converged_run(%{usage: %{}})
      kpis = KPIs.compute(run)

      assert kpis.cost_usd == nil
      assert kpis.cost_per_converged_predicate == nil
      # T34.8: an empty usage envelope reports NO token total either (absent ≠ 0).
      assert kpis.tokens == nil
      # The token/tool-derived KPIs are still present (their inputs were reported).
      assert kpis.fresh_input_tokens_avoided == 400
    end

    test "no converged predicate ⇒ the per-predicate ratios are nil (no divide-by-zero)" do
      run = converged_run(%{converged_predicates: 0})
      kpis = KPIs.compute(run)

      assert kpis.cost_per_converged_predicate == nil
      assert kpis.wall_clock_per_converged_predicate == nil
    end

    test "no recorded per-iteration counters ⇒ cache/re-discovery KPIs are nil (not zero)" do
      run = converged_run(%{iterations: []})
      kpis = KPIs.compute(run)

      assert kpis.fresh_input_tokens_avoided == nil
      assert kpis.rediscovery_tool_calls_avoided == nil
      assert kpis.wall_clock_s == nil
      # Run-aggregate KPIs survive without per-iteration data.
      assert kpis.cost_per_converged_predicate == 0.01
      assert kpis.iterations_to_convergence == 2
    end

    test "context recorded but no cache hit ⇒ a REAL measured zero, not nil" do
      run =
        converged_run(%{
          iterations: [
            %{
              converged: true,
              observed_at: ~U[2026-06-25 10:00:00.000000Z],
              context: %{"orientation_cache" => "miss", "orientation_tokens" => 400},
              tools: %{}
            }
          ]
        })

      kpis = KPIs.compute(run)
      assert kpis.fresh_input_tokens_avoided == 0
    end

    test "fewer than two tool-bearing iterations ⇒ rediscovery-avoided is nil (unmeasurable)" do
      run =
        converged_run(%{
          iterations: [
            %{
              converged: true,
              observed_at: ~U[2026-06-25 10:00:00.000000Z],
              context: %{"orientation_cache" => "hit", "orientation_tokens" => 100},
              # Only ONE iteration reports tools — no decline can be measured.
              tools: %{"file_reads" => 4, "search_calls" => 0, "graph_calls" => 0}
            }
          ]
        })

      kpis = KPIs.compute(run)
      assert kpis.rediscovery_tool_calls_avoided == nil
      assert kpis.fresh_input_tokens_avoided == 100
    end
  end

  describe "to_json/1 — the run-result economy object" do
    test "omits every unavailable KPI; status/stuck/iterations always present" do
      json = converged_run(%{usage: %{}, iterations: []}) |> KPIs.compute() |> KPIs.to_json()

      assert json["status"] == "converged"
      assert json["stuck"] == false
      assert json["iterations"] == 2
      # Unavailable KPIs are OMITTED (absent ≠ zero).
      refute Map.has_key?(json, "cost_usd")
      refute Map.has_key?(json, "tokens")
      refute Map.has_key?(json, "cost_per_converged_predicate")
      refute Map.has_key?(json, "fresh_input_tokens_avoided")
      refute Map.has_key?(json, "wall_clock_s")
    end

    test "includes the derivable KPIs and the breakdown labels" do
      json = converged_run() |> KPIs.compute() |> KPIs.to_json()

      assert json["harness"] == "claude"
      assert json["model"] == "haiku"
      assert json["context_tier"] == "C"
      assert json["cost_per_converged_predicate"] == 0.01
      assert json["tokens"] == 18_000
      assert json["fresh_input_tokens_avoided"] == 400
      assert json["rediscovery_tool_calls_avoided"] == 8
      assert json["iterations_to_convergence"] == 2
    end
  end

  describe "tokens — the run-aggregate token total (T34.8)" do
    test "sums every reported token component of the run-aggregate usage envelope" do
      # A live-shaped run-aggregate usage envelope: the four Anthropic token
      # classes the loop accumulates from each dispatch's parsed usage, plus the
      # harness's own dollar figure (Claude's total_cost_usd).
      run =
        converged_run(%{
          usage: %{
            input_tokens: 1_200,
            output_tokens: 800,
            cache_write_tokens: 5_000,
            cached_input_tokens: 18_000,
            cost_usd: 0.0731
          }
        })

      kpis = KPIs.compute(run)

      # NON-ZERO total = 1_200 + 800 + 5_000 + 18_000 (reasoning unreported, omitted).
      assert kpis.tokens == 25_000
      # The harness-reported cost is surfaced verbatim (authoritative for the model).
      assert kpis.cost_usd == 0.0731

      json = KPIs.to_json(kpis)
      assert json["tokens"] == 25_000
      assert json["cost_usd"] == 0.0731
    end

    test "a run reporting only cost (no token split) still omits tokens" do
      kpis = KPIs.compute(converged_run(%{usage: %{cost_usd: 0.05}}))

      assert kpis.tokens == nil
      assert kpis.cost_usd == 0.05
      refute Map.has_key?(KPIs.to_json(kpis), "tokens")
    end

    test "from_run_result round-trips the recorded economy tokens" do
      result = %{
        "status" => "converged",
        "economy" => %{"status" => "converged", "tokens" => 25_000, "cost_usd" => 0.0731},
        "usage" => %{"cost_usd" => 0.0731}
      }

      kpis = KPIs.from_run_result(result)
      assert kpis.tokens == 25_000
    end

    test "from_run_result derives tokens from the recorded usage split when economy omits it" do
      # A recorded result whose economy predates the tokens field but whose usage
      # envelope carries the split — the benchmark consumer still recovers the total.
      result = %{
        "status" => "converged",
        "usage" => %{"input_tokens" => 1_200, "output_tokens" => 800, "cost_usd" => 0.03}
      }

      kpis = KPIs.from_run_result(result)
      assert kpis.tokens == 2_000
    end
  end

  describe "aggregate/1 — breakdown by harness/model/context-tier with stuck-rate" do
    test "groups runs and folds the stuck-rate + per-converged-predicate means" do
      runs = [
        converged_run(%{model: "haiku", usage: %{cost_usd: 0.02}}),
        converged_run(%{model: "haiku", status: "stuck", usage: %{cost_usd: 0.04}}),
        converged_run(%{model: "sonnet", usage: %{cost_usd: 0.10}})
      ]

      groups = runs |> KPIs.compute_runs() |> KPIs.aggregate()

      haiku = Enum.find(groups, &(&1.model == "haiku"))
      sonnet = Enum.find(groups, &(&1.model == "sonnet"))

      assert haiku.runs == 2
      # One of the two haiku runs was stuck.
      assert haiku.stuck_rate == 0.5
      assert haiku.converged_rate == 0.5
      # mean of 0.02/2 and 0.04/2 = mean(0.01, 0.02) = 0.015.
      assert haiku.mean_cost_per_converged_predicate == 0.015

      assert sonnet.runs == 1
      assert sonnet.stuck_rate == 0.0
      assert sonnet.mean_cost_per_converged_predicate == 0.05
    end

    test "a group where NO run reported a field folds that KPI to nil (not zero)" do
      runs = [
        converged_run(%{usage: %{}, iterations: []}),
        converged_run(%{usage: %{}, iterations: []})
      ]

      [group] = runs |> KPIs.compute_runs() |> KPIs.aggregate()

      assert group.runs == 2
      # stuck-rate is always computable.
      assert group.stuck_rate == 0.0
      # but no cost was reported by any run ⇒ unavailable, not 0.
      assert group.mean_cost_per_converged_predicate == nil
      assert group.fresh_input_tokens_avoided == nil
    end
  end

  describe "render_table/1 — the deterministic benchmark table" do
    test "renders rows with n/a for unavailable cells" do
      groups =
        [converged_run(%{usage: %{}, iterations: []})]
        |> KPIs.compute_runs()
        |> KPIs.aggregate()

      table = KPIs.render_table(groups)

      assert table =~ "| Harness | Model | Tier | Runs |"
      assert table =~ "| claude | haiku | C |"
      # cost/wall/avoided are unavailable for this run ⇒ n/a, never 0.
      assert table =~ "n/a"
    end

    test "an empty breakdown yields the header-only table" do
      table = KPIs.render_table([])
      assert table =~ "| Harness | Model | Tier |"
      refute table =~ "| claude |"
    end
  end

  describe "from_run_result/2 — the benchmark consumes a recorded apply --json result" do
    test "reconstructs the per-run KPIs from a recorded result's economy object" do
      # A recorded `kazi apply --json` result object (decoded), exactly the shape
      # the CLI emits — the benchmark reads it back and re-derives nothing.
      result = %{
        "schema_version" => 2,
        "status" => "converged",
        "predicates" => [
          %{"id" => "code", "verdict" => "pass"},
          %{"id" => "live", "verdict" => "pass"}
        ],
        "iterations" => 3,
        "usage" => %{"cost_usd" => 0.06},
        "economy" => %{
          "status" => "converged",
          "stuck" => false,
          "iterations" => 3,
          "converged_predicates" => 2,
          "iterations_to_convergence" => 3,
          "cost_usd" => 0.06,
          "cost_per_converged_predicate" => 0.03,
          "fresh_input_tokens_avoided" => 1200,
          "rediscovery_tool_calls_avoided" => 5
        }
      }

      kpis = KPIs.from_run_result(result, %{context_tier: "C", harness: "claude", model: "haiku"})

      assert kpis.context_tier == "C"
      assert kpis.cost_per_converged_predicate == 0.03
      assert kpis.fresh_input_tokens_avoided == 1200
      assert kpis.rediscovery_tool_calls_avoided == 5

      # And it aggregates into the benchmark table.
      [group] = KPIs.aggregate([kpis])
      assert group.context_tier == "C"
      assert group.converged_rate == 1.0
      assert group.mean_cost_per_converged_predicate == 0.03
    end

    test "preserves honest-unknown across the round-trip — a result with no economy folds to nil KPIs" do
      result = %{
        "status" => "stuck",
        "predicates" => [%{"id" => "code", "verdict" => "fail"}],
        "iterations" => 1
      }

      kpis = KPIs.from_run_result(result, %{context_tier: "B"})

      assert kpis.status == "stuck"
      assert kpis.stuck == true
      assert kpis.converged_predicates == 0
      assert kpis.cost_per_converged_predicate == nil
      assert kpis.fresh_input_tokens_avoided == nil
    end
  end

  describe "token_breakdown/1 (T60.5, #1070)" do
    test "reads each category from the usage envelope, atom-keyed" do
      usage = %{
        input_tokens: 100,
        output_tokens: 250,
        cached_input_tokens: 5000,
        cache_write_tokens: 0
      }

      assert KPIs.token_breakdown(usage) == %{
               input: 100,
               output: 250,
               cached: 5000,
               cache_write: 0
             }
    end

    test "reads each category from the usage envelope, string-keyed (JSON round-trip)" do
      usage = %{"input_tokens" => 100, "output_tokens" => 250}

      assert KPIs.token_breakdown(usage) == %{
               input: 100,
               output: 250,
               cached: nil,
               cache_write: nil
             }
    end

    test "an unreported category is nil, never a fabricated 0" do
      assert KPIs.token_breakdown(%{}) == %{
               input: nil,
               output: nil,
               cached: nil,
               cache_write: nil
             }
    end

    test "a non-map input degrades to all-nil rather than raising" do
      assert KPIs.token_breakdown(nil) == %{
               input: nil,
               output: nil,
               cached: nil,
               cache_write: nil
             }
    end
  end
end
