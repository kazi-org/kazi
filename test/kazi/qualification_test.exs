defmodule Kazi.QualificationTest do
  use ExUnit.Case, async: false
  alias Kazi.{Authoring, Goal, Predicate, PredicateResult, Qualification, Runtime}
  @moduletag :tmp_dir
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  defmodule Provider do
    def evaluate(predicate, _context), do: PredicateResult.new(predicate.config.status)
  end

  defmodule NeverWorker do
    def run(_, _, _) do
      raise "qualification launched an unqualified worker"
    end
  end

  test "green, unknown, error and landing-only red never dispatch", %{tmp_dir: work} do
    for status <- [:pass, :unknown, :error] do
      goal =
        Goal.new("qualify-#{status}",
          qualification: %{required_red: ["behavior"]},
          predicates: [
            Predicate.new("behavior", :custom_script,
              acceptance?: true,
              config: %{status: status}
            ),
            Predicate.new("landed", :custom_script, acceptance?: true, config: %{status: :fail})
          ]
        )

      assert {:error, {:qualification_failed, evidence}} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: "/nonexistent-qualification-worker"],
                 providers: %{custom_script: Provider},
                 persist?: false
               )

      assert evidence["verdicts"]["behavior"] == to_string(status)
    end
  end

  test "required ids validate and round trip through proposal", %{tmp_dir: _work} do
    payload = %{
      "predicates" => [
        %{"id" => "behavior", "provider" => "custom_script", "config" => %{"cmd" => "true"}}
      ],
      "qualification" => %{"required_red" => ["behavior"]},
      "setup" => %{"commands" => ["true"]}
    }

    assert {:ok, goal} = Authoring.parse_proposal(payload, "qualified")
    assert {:ok, loaded} = Goal.Loader.from_map(Authoring.serialize_goal(goal))
    assert loaded.qualification == goal.qualification
    assert loaded.setup == goal.setup

    for ids <- [[], ["missing"], ["landed"], [true], ["behavior", "behavior"]] do
      assert {:error, _} = Qualification.parse(%{"required_red" => ids}, goal.predicates)
    end

    guard = Predicate.new("guard", :custom_script, guard?: true)
    assert {:error, _} = Qualification.parse(%{"required_red" => ["guard"]}, [guard])
  end

  test "a genuine red baseline dispatches and retains provenance", %{tmp_dir: work} do
    script = Path.join(work, "worker.sh")
    File.write!(script, "#!/bin/sh\ntouch fixed\n")
    File.chmod!(script, 0o755)

    predicate =
      Predicate.new("behavior", :custom_script,
        acceptance?: true,
        config: %{cmd: "sh", args: ["-c", "test -f fixed"], verdict: "exit_zero"}
      )

    goal =
      Goal.new("qualification-repair",
        predicates: [predicate],
        qualification: %{required_red: ["behavior"]}
      )

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               adapter_opts: [command: script],
               reobserve_interval_ms: 5,
               await_timeout: 15_000
             )

    assert result.outcome == :converged
    assert result.qualification["verdicts"] == %{"behavior" => "fail"}
    row = Kazi.Repo.get_by!(Kazi.ReadModel.Run, run_id: result.run_id)

    assert row.qualification["evaluator_fingerprint"] ==
             result.qualification["evaluator_fingerprint"]

    assert row.qualification["baseline"]["kind"] == "non_git"
  end
end
