defmodule Kazi.CLI.AccountingProvenanceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Kazi.ReadModel.{Run, RunRegistry}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    root = Path.join(System.tmp_dir!(), "kazi-accounting-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  for entry <- [:file, :proposal], second_report <- [true, false] do
    test "#{entry} failed attempt and second-report=#{second_report} survive every JSON consumer",
         %{root: root} do
      id = "accounting-#{Ecto.UUID.generate()}"

      first = %{
        "modelUsage" => %{
          "fixture" => %{
            "inputTokens" => 10_000,
            "outputTokens" => 42_533,
            "cacheReadInputTokens" => 1_300_000,
            "cacheCreationInputTokens" => 0
          }
        },
        "usage" => %{
          "input_tokens" => 1_277_629,
          "output_tokens" => 0,
          "cache_read_input_tokens" => 0,
          "cache_creation_input_tokens" => 0
        },
        "total_cost_usd" => 2.017401
      }

      second =
        if unquote(second_report),
          do: %{
            "modelUsage" => %{
              "fixture" => %{
                "inputTokens" => 10,
                "outputTokens" => 20,
                "cacheReadInputTokens" => 50,
                "cacheCreationInputTokens" => 20
              }
            }
          },
          else: %{"result" => "done"}

      worker = worker(root, first, second)

      ref =
        if unquote(entry) == :proposal do
          payload = %{
            "goal_id" => id,
            "predicates" => [
              %{
                "id" => "code",
                "provider" => "custom_script",
                "config" => %{
                  "cmd" => "sh",
                  "args" => ["-c", "test -f fixed"],
                  "verdict" => "exit_zero"
                }
              }
            ],
            "budget" => %{"max_total_dispatches" => 2},
            "enforcement" => %{"enabled" => false}
          }

          ref =
            json_cli(["plan", "--json", "--predicates", Jason.encode!(payload)])["proposal_ref"]

          json_cli(["approve", ref, "--json"])
          ref
        else
          path = Path.join(root, "goal.toml")

          File.write!(path, """
          id = "#{id}"
          [budget]
          max_total_dispatches = 2
          [enforcement]
          enabled = false
          [[predicate]]
          id = "code"
          provider = "custom_script"
          cmd = "sh"
          args = ["-c", "test -f fixed"]
          verdict = "exit_zero"
          """)

          path
        end

      result =
        json_cli(["apply", ref, "--workspace", root, "--model", "fixture-unpriced", "--json"],
          adapter_opts: [command: worker],
          sinks_dir: Path.join(root, "sinks"),
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )

      assert result["status"] == "converged"
      assert File.read!(Path.join(root, "count")) == "2\n"
      expected = 1_352_533 + if(unquote(second_report), do: 100, else: 0)
      assert result["budget_spent"]["tokens"] == expected
      assert result["economy"]["tokens"] == expected
      assert result["usage"]["cost_usd"] == 2.017401
      p = result["usage_provenance"]
      assert p["dispatches"] == 2
      assert p["usage_reports"] == if(unquote(second_report), do: 2, else: 1)
      assert p["usage_coverage"] == if(unquote(second_report), do: "complete", else: "partial")
      assert p["cost_reports"] == 1
      assert p["cost_coverage"] == "partial"
      assert p["cost_basis"] == "harness_reported_unverified"
      assert p["reported_cost_usd"] == 2.017401
      assert p["actual_cost_usd"] == nil
      assert result["economy"]["usage_provenance"] == p
      run = Kazi.Repo.get_by!(Run, goal_ref: id)
      assert run.budget_tokens == expected
      assert run.usage == result["usage"]
      assert run.usage_provenance == p
      # A repeated terminal write replaces cumulative facts; it does not add them.
      assert {:ok, _} =
               RunRegistry.finish(run.run_id, "converged", %{
                 usage: run.usage,
                 usage_provenance: p,
                 budget_tokens: expected,
                 budget_cost_usd: 2.017401
               })

      status = json_cli(["status", id, "--json"])
      assert status["usage"] == result["usage"]
      assert status["usage_provenance"] == p
      [group] = json_cli(["economy", "--goal", id, "--json"])["groups"]
      assert group["tokens"]["p50"] == expected
      assert group["usage_provenance"]["known_dispatches"] == 2
      assert group["usage_provenance"]["known_reported_cost_usd"] == 2.017401
      assert group["usage_provenance"]["actual_cost_usd"] == nil
    end
  end

  test "a sealed-input refusal persists the final worker report without inventing a passing observation",
       %{root: root} do
    id = "tamper-accounting-#{Ecto.UUID.generate()}"
    File.write!(Path.join(root, "check.sh"), "exit 1\n")
    worker = Path.join(root, "worker.sh")

    File.write!(worker, """
    #!/bin/sh
    echo 'exit 0' > check.sh
    echo '{"usage":{"input_tokens":17},"total_cost_usd":0.25}'
    """)

    File.chmod!(worker, 0o755)
    goal = Path.join(root, "goal.toml")

    File.write!(goal, """
    id = "#{id}"
    [seal]
    sealed_inputs = ["check.sh"]
    [enforcement]
    enabled = false
    [[predicate]]
    id = "code"
    provider = "custom_script"
    cmd = "sh"
    args = ["check.sh"]
    verdict = "exit_zero"
    """)

    output =
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["apply", goal, "--workspace", root, "--model", "fixture-unpriced", "--json"],
                 adapter_opts: [command: worker],
                 sinks_dir: Path.join(root, "sinks"),
                 reobserve_interval_ms: 5,
                 await_timeout: 15_000
               ) == 1
      end)

    result = Jason.decode!(String.trim(output))
    assert result["status"] == "tampered"
    p = result["usage_provenance"]
    assert p["dispatches"] == 1
    assert p["reported_cost_usd"] == 0.25
    status = json_cli(["status", id, "--json"])
    assert status["usage_provenance"] == p
    assert status["usage"] == result["usage"]
    row = Kazi.ReadModel.latest_iteration(id)
    refute row.converged
    assert row.predicate_vector["code"]["status"] == "fail"
    refute row.action_kind == "budget_stop"
    assert Kazi.Repo.get_by!(Run, goal_ref: id).usage_provenance == p
    [group] = json_cli(["economy", "--goal", id, "--json"])["groups"]
    assert group["usage_provenance"]["known_reported_cost_usd"] == 0.25
  end

  test "price-map estimates disclose partial coverage and never imply settled spend", %{
    root: root
  } do
    worker = worker(root, %{"usage" => %{"output_tokens" => 100}}, %{})

    assert {:ok, result} =
             Kazi.Harness.ClaudeAdapter.run("fixture", root,
               command: worker,
               model: "claude-opus-4-8"
             )

    assert result.exit == 1
    assert result.cost_basis == :price_map_estimate
    assert result.cost_fidelity == :partial_token_split
    assert result.price_map_as_of == Kazi.Economy.PriceMap.as_of()
    assert result.cost_usd == 0.0025
  end

  test "historical rows retain unknown provenance and cumulative upserts replace snapshots" do
    id = "historical-#{Ecto.UUID.generate()}"

    {:ok, run} =
      RunRegistry.start(%{
        run_id: id,
        goal_ref: id,
        pid: "fixture",
        workspace: "/fixture",
        harness: "claude",
        model: "fixture"
      })

    {:ok, _} = RunRegistry.finish(run.run_id, "converged", %{budget_cost_usd: 2.017401})
    vector = Kazi.PredicateVector.new(%{"code" => Kazi.PredicateResult.new(:pass, %{})})

    attrs = %{
      goal_ref: id,
      iteration_index: 0,
      predicate_vector: vector,
      observed_at: DateTime.utc_now(),
      converged: true,
      upsert?: true
    }

    {:ok, _} = Kazi.ReadModel.record_iteration(attrs)
    assert json_cli(["status", id, "--json"])["usage_provenance"]["usage_coverage"] == "unknown"
    [group] = json_cli(["economy", "--goal", id, "--json"])["groups"]
    assert group["cost_usd"]["p50"] == 2.017401
    assert group["usage_provenance"]["unknown_historical_runs"] == 1
    assert group["usage_provenance"]["actual_cost_usd"] == nil

    first =
      Kazi.Economy.UsageProvenance.new()
      |> Kazi.Economy.UsageProvenance.record({:error, :timeout})

    second = Kazi.Economy.UsageProvenance.record(first, {:ok, %{usage: %{input_tokens: 5}}})

    for p <- [first, second, second] do
      {:ok, _} =
        Kazi.ReadModel.record_iteration(
          Map.merge(attrs, %{usage: %{input_tokens: 5}, usage_provenance: p})
        )
    end

    assert json_cli(["status", id, "--json"])["usage_provenance"] == second
  end

  for dollars <- [nil, 0.0] do
    test "no token reports and reported dollars #{inspect(dollars)} keep token totals unknown", %{
      root: root
    } do
      id = "no-usage-#{Ecto.UUID.generate()}"
      first = if is_nil(unquote(dollars)), do: %{}, else: %{"total_cost_usd" => unquote(dollars)}
      worker = worker(root, first, %{})

      payload = %{
        "goal_id" => id,
        "predicates" => [
          %{
            "id" => "code",
            "provider" => "custom_script",
            "config" => %{
              "cmd" => "sh",
              "args" => ["-c", "test -f fixed"],
              "verdict" => "exit_zero"
            }
          }
        ],
        "budget" => %{"max_total_dispatches" => 2},
        "enforcement" => %{"enabled" => false}
      }

      ref = json_cli(["plan", "--json", "--predicates", Jason.encode!(payload)])["proposal_ref"]
      json_cli(["approve", ref, "--json"])

      result =
        json_cli(["apply", ref, "--workspace", root, "--model", "fixture-unpriced", "--json"],
          adapter_opts: [command: worker],
          sinks_dir: Path.join(root, "sinks"),
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )

      p = result["usage_provenance"]
      assert p["dispatches"] == 2
      assert p["usage_reports"] == 0
      assert p["usage_coverage"] == "none"
      assert p["reported_cost_usd"] == unquote(dollars)
      refute Map.has_key?(result["economy"], "tokens")
      run = Kazi.Repo.get_by!(Run, goal_ref: id)
      assert run.budget_tokens == nil
      assert run.budget_cost_usd == unquote(dollars)
      assert run.usage_provenance == p
      assert json_cli(["status", id, "--json"])["usage_provenance"] == p
      [group] = json_cli(["economy", "--goal", id, "--json"])["groups"]
      assert group["tokens"]["p50"] == nil
      assert group["cost_usd"]["p50"] == unquote(dollars)
    end
  end

  defp worker(root, first, second) do
    path = Path.join(root, "worker.sh")

    File.write!(path, """
    #!/bin/sh
    n=$(cat count 2>/dev/null || echo 0)
    n=$((n+1))
    echo "$n" > count
    if test "$n" = 1; then
      cat <<'JSON'
    #{Jason.encode!(first)}
    JSON
      exit 1
    fi
    touch fixed
    cat <<'JSON'
    #{Jason.encode!(second)}
    JSON
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp json_cli(args, opts \\ []) do
    output = capture_io(fn -> assert Kazi.CLI.run(args, opts) == 0 end)
    result = Jason.decode!(String.trim(output))
    assert result["schema_version"] == 2
    result
  end
end
