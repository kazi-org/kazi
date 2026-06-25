defmodule Kazi.ReadModelTest do
  @moduledoc """
  Tier 2 — real SQLite boundary. Inserts iterations through `Kazi.ReadModel`,
  reads them back, and asserts the round-trip including the serialized evidence
  vector (T0.9, UC-006).
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially.
  use ExUnit.Case, async: false

  alias Kazi.{Action, PredicateResult, PredicateVector, Repo}
  alias Kazi.ReadModel

  setup do
    # Per-test transaction via the SQLite3 Sandbox — isolates rows between tests.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp sample_vector do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0, output: "12 tests, 0 failures", duration_ms: 1200}),
      probe: PredicateResult.fail(%{http_status: 503, url: "https://example.test/healthz"})
    })
  end

  test "records an iteration and reads it back with the serialized evidence" do
    vector = sample_vector()
    action = Action.new(:dispatch_agent, params: %{"failing" => ["probe"]})
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, inserted} =
             ReadModel.record_iteration(%{
               goal_ref: "ship-it",
               iteration_index: 0,
               predicate_vector: vector,
               action: action,
               observed_at: observed_at
             })

    assert inserted.goal_ref == "ship-it"
    assert inserted.iteration_index == 0
    # A vector with a failing predicate is not converged (defaulted from the
    # vector).
    assert inserted.converged == false
    assert inserted.action_kind == "dispatch_agent"

    fetched = ReadModel.get_iteration("ship-it", 0)
    assert fetched.id == inserted.id

    # Round-trip the serialized evidence back into a PredicateVector.
    round_tripped = ReadModel.to_predicate_vector(fetched)
    assert PredicateVector.failing(round_tripped) == ["probe"]

    unit = PredicateVector.get(round_tripped, "unit")
    assert unit.status == :pass
    assert unit.evidence["output"] == "12 tests, 0 failures"
    assert unit.evidence["exit"] == 0

    probe = PredicateVector.get(round_tripped, "probe")
    assert probe.status == :fail
    assert probe.evidence["http_status"] == 503

    # Action params survived.
    assert fetched.action_params == %{"failing" => ["probe"]}
  end

  test "round-trips the per-iteration context + tool counters (T34.3)" do
    assert {:ok, _inserted} =
             ReadModel.record_iteration(%{
               goal_ref: "counters-goal",
               iteration_index: 0,
               predicate_vector: sample_vector(),
               observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
               context: %{
                 orientation_cache: "hit",
                 retrieval_cache: "disabled",
                 orientation_tokens: 120,
                 evidence_tokens: 30,
                 retrieval_tokens: 0
               },
               tools: %{tool_calls: 4, file_reads: 2, search_calls: 1, graph_calls: 1}
             })

    fetched = ReadModel.get_iteration("counters-goal", 0)

    # Stored JSON-safe with stringified keys; values (strings/integers) survive.
    assert fetched.context == %{
             "orientation_cache" => "hit",
             "retrieval_cache" => "disabled",
             "orientation_tokens" => 120,
             "evidence_tokens" => 30,
             "retrieval_tokens" => 0
           }

    assert fetched.tools == %{
             "tool_calls" => 4,
             "file_reads" => 2,
             "search_calls" => 1,
             "graph_calls" => 1
           }
  end

  test "an iteration recorded without counters deserializes to empty maps (back-compat, T34.3)" do
    # The pre-T34.3 shape: no :context / :tools attrs. The additive columns default
    # to %{}, so old-shape records still read back cleanly.
    assert {:ok, _inserted} =
             ReadModel.record_iteration(%{
               goal_ref: "no-counters-goal",
               iteration_index: 0,
               predicate_vector: sample_vector(),
               observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })

    fetched = ReadModel.get_iteration("no-counters-goal", 0)
    assert fetched.context == %{}
    assert fetched.tools == %{}
  end

  test "persists an errored predicate whose evidence holds tuples + atom keys (T18.2)" do
    # The exact crash from the token benchmark: a test_runner that cannot exec its
    # cmd yields an :error result whose evidence carries a tuple reason and atom
    # keys. Stored verbatim this failed the Ecto :map cast and record_iteration/1
    # raised, silently dropping the iteration. It must now persist + round-trip.
    vector =
      PredicateVector.new(%{
        "go-tests" =>
          PredicateResult.error(%{
            reason: {:cmd_unrunnable, "Erlang error: :enoent"},
            cmd: "go test ./...",
            args: [],
            workspace: "/tmp/ws"
          })
      })

    assert {:ok, inserted} =
             ReadModel.record_iteration(%{
               goal_ref: "errored-goal",
               iteration_index: 0,
               predicate_vector: vector,
               observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })

    fetched = ReadModel.get_iteration("errored-goal", 0)
    assert fetched.id == inserted.id

    round_tripped = ReadModel.to_predicate_vector(fetched)
    result = PredicateVector.get(round_tripped, "go-tests")
    assert result.status == :error
    # The tuple reason is rendered to a readable string; scalars survive as-is.
    assert result.evidence["reason"] =~ "cmd_unrunnable"
    assert result.evidence["cmd"] == "go test ./..."
    assert result.evidence["args"] == []
  end

  # ===========================================================================
  # Envelope v2 — score / direction / prior_score / diagnostics (ADR-0041, T32.2)
  # ===========================================================================

  test "a graded result round-trips score, direction, prior_score, and evidence" do
    diag = Kazi.Evidence.new(file: "lib/a.ex", line: 14, rule: "no-unused", level: :warning)

    vector =
      PredicateVector.new(%{
        lint:
          PredicateResult.new(:fail, %{output: "30 warnings"},
            score: 12.0,
            direction: :lower_better,
            prior_score: 30.0,
            diagnostics: [diag]
          )
      })

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "graded-goal",
               iteration_index: 0,
               predicate_vector: vector,
               observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })

    fetched = ReadModel.get_iteration("graded-goal", 0)

    # Raw stored shape carries the additive keys (an orchestrator reads these).
    # The raw provider map stays under "evidence" (legacy field); the structured
    # LSP-Diagnostic items are stored under "diagnostics" (the struct field name).
    stored = fetched.predicate_vector["lint"]
    assert stored["status"] == "fail"
    assert stored["score"] == 12.0
    assert stored["prior_score"] == 30.0
    assert stored["direction"] == "lower_better"
    assert stored["evidence"] == %{"output" => "30 warnings"}

    assert stored["diagnostics"] == [
             %{"file" => "lib/a.ex", "line" => 14, "rule" => "no-unused", "level" => "warning"}
           ]

    # Rehydrated back into the domain struct.
    result = PredicateVector.get(ReadModel.to_predicate_vector(fetched), "lint")
    assert result.score == 12.0
    assert result.direction == :lower_better
    assert result.prior_score == 30.0
    assert result.diagnostics == [diag]
    # The interpreted gradient survives: 30 → 12 lower_better is progress.
    assert PredicateResult.progress(result) == :progressed
  end

  test "a boolean predicate's stored shape is UNCHANGED — exactly status + evidence (back-compat)" do
    vector =
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0, output: "ok"}),
        probe: PredicateResult.fail(%{http_status: 503})
      })

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "boolean-goal",
               iteration_index: 0,
               predicate_vector: vector,
               observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })

    fetched = ReadModel.get_iteration("boolean-goal", 0)

    # The serialized map for a boolean result has EXACTLY two keys — no score,
    # prior_score, direction, or evidence/diagnostics leaked in. This is the
    # byte-identical guarantee the envelope-v2 additive design rests on.
    assert Map.keys(fetched.predicate_vector["unit"]) |> Enum.sort() == ["evidence", "status"]
    assert Map.keys(fetched.predicate_vector["probe"]) |> Enum.sort() == ["evidence", "status"]

    assert fetched.predicate_vector["unit"] == %{
             "status" => "pass",
             "evidence" => %{"exit" => 0, "output" => "ok"}
           }
  end

  test "defaults converged to whether the full vector is satisfied" do
    all_pass =
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0}),
        probe: PredicateResult.pass(%{http_status: 200})
      })

    assert {:ok, converged} =
             ReadModel.record_iteration(%{
               goal_ref: "done-goal",
               iteration_index: 3,
               predicate_vector: all_pass
             })

    assert converged.converged == true
    # No action at the terminal converged observation.
    assert converged.action_kind == nil
    assert converged.action_params == %{}
  end

  test "lists iterations for a goal in iteration order" do
    for idx <- [2, 0, 1] do
      assert {:ok, _} =
               ReadModel.record_iteration(%{
                 goal_ref: "multi",
                 iteration_index: idx,
                 predicate_vector: sample_vector()
               })
    end

    indices = "multi" |> ReadModel.list_iterations() |> Enum.map(& &1.iteration_index)
    assert indices == [0, 1, 2]

    assert ReadModel.latest_iteration("multi").iteration_index == 2
  end

  test "iteration_history/1 returns the per-iteration vectors in order (T1.1)" do
    # Two distinct vectors recorded out of order; the history must come back
    # oldest-first with each iteration's FULL vector rehydrated.
    iter0 =
      PredicateVector.new(%{
        unit: PredicateResult.fail(%{exit: 1}),
        probe: PredicateResult.fail(%{http_status: 503})
      })

    iter1 =
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0}),
        probe: PredicateResult.pass(%{http_status: 200})
      })

    # Insert index 1 before index 0 to prove ordering is by iteration_index.
    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "hist",
               iteration_index: 1,
               predicate_vector: iter1
             })

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "hist",
               iteration_index: 0,
               predicate_vector: iter0
             })

    history = ReadModel.iteration_history("hist")

    assert [{0, v0}, {1, v1}] = history

    # iter0: both predicates failing (full vector preserved, keyed by string id).
    assert MapSet.new(PredicateVector.failing(v0)) == MapSet.new(["unit", "probe"])
    assert PredicateVector.get(v0, "probe").evidence["http_status"] == 503

    # iter1: the satisfied convergence vector.
    assert PredicateVector.satisfied?(v1)
    assert PredicateVector.get(v1, "unit").status == :pass
  end

  test "iteration_history/1 is empty for a goal with no recorded iterations (T1.1)" do
    assert ReadModel.iteration_history("never-ran") == []
  end

  test "rejects a duplicate (goal_ref, iteration_index)" do
    attrs = %{goal_ref: "dup", iteration_index: 0, predicate_vector: sample_vector()}

    assert {:ok, _} = ReadModel.record_iteration(attrs)
    assert {:error, changeset} = ReadModel.record_iteration(attrs)
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :iteration_index)
  end

  test "upsert? replaces an existing index instead of colliding (T18.3)" do
    # The terminal/stuck projection reuses the last observed iteration_index. With
    # upsert? it must replace that row's final state, not error on the unique index.
    failing = sample_vector()

    assert {:ok, first} =
             ReadModel.record_iteration(%{
               goal_ref: "terminal",
               iteration_index: 0,
               predicate_vector: failing
             })

    converged =
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0}),
        probe: PredicateResult.pass(%{http_status: 200})
      })

    assert {:ok, second} =
             ReadModel.record_iteration(%{
               goal_ref: "terminal",
               iteration_index: 0,
               predicate_vector: converged,
               action: Kazi.Action.new(:budget_stop, params: %{reason: :max_iterations}),
               upsert?: true
             })

    # Same row (same id), replaced state — not a second row, not an error.
    assert first.id == second.id
    assert [{0, v0}] = ReadModel.iteration_history("terminal")
    assert PredicateVector.satisfied?(v0)
    assert ReadModel.get_iteration("terminal", 0).action_kind == "budget_stop"
  end

  test "records + reads back regression flags (T1.2), with the attributed dispatch" do
    flag = %{
      predicate_id: :keep,
      green_iteration: 0,
      red_iteration: 1,
      status: :fail,
      attributed_dispatch: Action.new(:dispatch_agent, params: %{failing: [:fix]})
    }

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "regressed",
               iteration_index: 0,
               predicate_vector: sample_vector()
             })

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "regressed",
               iteration_index: 1,
               predicate_vector: sample_vector(),
               regressions: [flag]
             })

    # Only the iteration that flagged a regression is returned, keyed by index.
    assert [{1, [stored]}] = ReadModel.regressions("regressed")
    assert stored["predicate_id"] == "keep"
    assert stored["green_iteration"] == 0
    assert stored["red_iteration"] == 1
    assert stored["status"] == "fail"
    # The attributed dispatch survives the JSON round-trip, flattened to its kind.
    assert stored["attributed_dispatch"]["kind"] == "dispatch_agent"
  end

  test "regressions/1 is empty when no iteration flagged a regression (T1.2)" do
    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "clean",
               iteration_index: 0,
               predicate_vector: sample_vector()
             })

    assert ReadModel.regressions("clean") == []
  end

  # --- Release tagging round-trip (T3.3c, UC-015) ----------------------------

  test "a release ref from a successful deploy persists and reads back (T3.3c)" do
    # Drive a real (stubbed) deploy so the release ref under test is the one the
    # action actually produces, then persist it through the read-model and read
    # it back — the full deploy → record → query round-trip, hermetically.
    dir = Path.join(System.tmp_dir!(), "kazi_release_rt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    deploy_stub = Path.join(dir, "gcloud_ok")

    File.write!(deploy_stub, """
    #!/bin/sh
    echo "https://kazi-rt-uc.a.run.app"
    exit 0
    """)

    File.chmod!(deploy_stub, 0o755)

    tagger = Path.join(dir, "git_ok")
    File.write!(tagger, "#!/bin/sh\nexit 0\n")
    File.chmod!(tagger, 0o755)

    deploy_action =
      Action.new(:deploy,
        params: %{
          cmd: deploy_stub,
          tag_cmd: tagger,
          release_ref: "release-kazi-rt-1",
          service: "kazi-rt",
          project: "p",
          region: "r",
          source: "."
        }
      )

    assert {:ok, %{release_ref: release_ref}} =
             Kazi.Actions.Deploy.execute(deploy_action, %{})

    assert release_ref == "release-kazi-rt-1"

    # Persist the deploy iteration carrying the release ref.
    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "shipped",
               iteration_index: 0,
               predicate_vector: sample_vector(),
               action: deploy_action,
               release_ref: release_ref
             })

    # The release ref round-trips through SQLite on the iteration row.
    fetched = ReadModel.get_iteration("shipped", 0)
    assert fetched.release_ref == "release-kazi-rt-1"

    # And it is queryable across the goal's history.
    assert [{0, "release-kazi-rt-1"}] = ReadModel.release_refs("shipped")
  end

  test "release_refs/1 omits iterations with no release ref (T3.3c)" do
    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "no-deploy",
               iteration_index: 0,
               predicate_vector: sample_vector()
             })

    assert ReadModel.release_refs("no-deploy") == []
  end

  # --- Goal board summary (T3.6b, UC-018) ------------------------------------

  describe "list_goals/0 (goal board)" do
    test "returns an empty list when no iterations are recorded" do
      assert ReadModel.list_goals() == []
    end

    test "summarises each goal with status, latest vector, and iteration count" do
      failing =
        PredicateVector.new(%{
          unit: PredicateResult.pass(%{exit: 0}),
          probe: PredicateResult.fail(%{http_status: 503})
        })

      converged =
        PredicateVector.new(%{
          unit: PredicateResult.pass(%{exit: 0}),
          probe: PredicateResult.pass(%{http_status: 200})
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "board-a",
          iteration_index: 0,
          predicate_vector: failing
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "board-a",
          iteration_index: 1,
          predicate_vector: converged,
          converged: true
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "board-b",
          iteration_index: 0,
          predicate_vector: failing
        })

      by_ref = Map.new(ReadModel.list_goals(), &{&1.goal_ref, &1})

      a = by_ref["board-a"]
      assert a.status == :converged
      assert a.iteration_count == 2
      # The latest vector is the converged one → 2/2 passing.
      assert Kazi.ReadModel.GoalSummary.predicate_summary(a) == {2, 2}

      b = by_ref["board-b"]
      assert b.status == :in_progress
      assert b.iteration_count == 1
      assert Kazi.ReadModel.GoalSummary.predicate_summary(b) == {1, 2}
    end

    test "orders goals by last observation, most recent first" do
      vector = PredicateVector.new(%{unit: PredicateResult.pass(%{exit: 0})})
      older = ~U[2026-06-22 10:00:00.000000Z]
      newer = ~U[2026-06-22 11:00:00.000000Z]

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "older-goal",
          iteration_index: 0,
          predicate_vector: vector,
          observed_at: older
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "newer-goal",
          iteration_index: 0,
          predicate_vector: vector,
          observed_at: newer
        })

      assert ["newer-goal", "older-goal"] ==
               Enum.map(ReadModel.list_goals(), & &1.goal_ref)
    end
  end
end
