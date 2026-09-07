defmodule Kazi.CLI.AcceptanceIntegrityTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    work = Path.join(System.tmp_dir!(), "kazi-integrity-#{Ecto.UUID.generate()}")
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)
    {:ok, work: work}
  end

  test "constant and unrunnable verifiers launch no worker and retain refusal evidence", %{
    work: root
  } do
    for checker <- ["exit 0", "exit 1", "missing-child-command"] do
      work = Path.join(root, Ecto.UUID.generate())
      File.mkdir_p!(work)
      File.write!(Path.join(work, "check.sh"), checker <> "\n")

      payload = %{
        "goal_id" => Ecto.UUID.generate(),
        "predicates" => [
          %{
            "id" => "behavior",
            "provider" => "custom_script",
            "config" => %{
              "cmd" => "sh",
              "args" => ["check.sh"],
              "verdict" => "json",
              "path" => "$.failures",
              "pass_when" => "== 0"
            }
          }
        ],
        "qualification" => %{"required_red" => ["behavior"]},
        "enforcement" => %{"enabled" => false}
      }

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", Jason.encode!(payload)]) == 0
        end)

      ref = Jason.decode!(String.trim(out))["proposal_ref"]
      capture_io(fn -> assert Kazi.CLI.run(["approve", ref, "--json"]) == 0 end)
      worker = Path.join(work, "worker.sh")
      File.write!(worker, "#!/bin/sh\ntouch launched\n")
      File.chmod!(worker, 0o755)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"],
                   adapter_opts: [command: worker]
                 ) == 1
        end)

      assert Jason.decode!(String.trim(out))["status"] == "error"
      refute File.exists?(Path.join(work, "launched"))
      row = Kazi.Repo.get_by!(Kazi.ReadModel.Run, goal_ref: payload["goal_id"])
      assert row.qualification["verdicts"]["behavior"] == "error"
    end
  end

  test "public proposal and file paths admit real repair and reject blanket success", %{
    work: root
  } do
    for entry <- [:proposal, :file], repair <- [:correct, :stub] do
      work = Path.join(root, "#{entry}-#{repair}")
      File.mkdir_p!(work)
      File.write!(Path.join(work, "app.sh"), "echo 0\n")

      File.write!(Path.join(work, "check.sh"), """
      set -eu
      failures=0
      test "$(sh app.sh 2)" = 4 || failures=$((failures+1))
      test "$(sh app.sh 3)" = 6 || failures=$((failures+1))
      test "$(sh app.sh invalid)" = error || failures=$((failures+1))
      if test "$failures" = 0; then echo 3 > executed-count; fi
      printf '{"failures":%s}\\n' "$failures"
      """)

      config = %{
        "cmd" => "sh",
        "args" => ["check.sh"],
        "verdict" => "json",
        "path" => "$.failures",
        "pass_when" => "== 0"
      }

      payload = %{
        "goal_id" => "integrity-#{entry}-#{repair}",
        "predicates" => [%{"id" => "behavior", "provider" => "custom_script", "config" => config}],
        "qualification" => %{"required_red" => ["behavior"]},
        "seal" => %{"sealed_inputs" => ["check.sh"]},
        "enforcement" => %{"enabled" => false}
      }

      ref =
        case entry do
          :proposal ->
            out =
              capture_io(fn ->
                assert Kazi.CLI.run(["plan", "--json", "--predicates", Jason.encode!(payload)]) ==
                         0
              end)

            ref = Jason.decode!(String.trim(out))["proposal_ref"]
            capture_io(fn -> assert Kazi.CLI.run(["approve", ref, "--json"]) == 0 end)
            ref

          :file ->
            path = Path.join(work, "goal.toml")

            File.write!(path, """
            id = "integrity-file-#{repair}"
            mode = "create"
            [qualification]
            required_red = ["behavior"]
            [enforcement]
            enabled = false
            [seal]
            sealed_inputs = ["check.sh"]
            [[predicate]]
            id = "behavior"
            provider = "custom_script"
            acceptance = true
            cmd = "sh"
            args = ["check.sh"]
            verdict = "json"
            path = "$.failures"
            pass_when = "== 0"
            """)

            path
        end

      fix =
        if repair == :correct,
          do: "case $1 in invalid) echo error;; *) expr \\\"$1\\\" \\\\* 2;; esac",
          else: "exit 0"

      # Keep the candidate shell source literal in the worker's heredoc.
      fix = String.replace(fix, "\\\"", "\"") |> String.replace("\\\\*", "\\*")
      worker = Path.join(work, "worker.sh")
      File.write!(worker, "#!/bin/sh\ncat > app.sh <<'APP'\n#{fix}\nAPP\n")
      File.chmod!(worker, 0o755)

      out =
        capture_io(fn ->
          code =
            Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"],
              budget: Kazi.Budget.new(max_iterations: 3),
              adapter_opts: [command: worker],
              reobserve_interval_ms: 5,
              await_timeout: 15_000
            )

          assert code == if(repair == :correct, do: 0, else: 1)
        end)

      result = Jason.decode!(String.trim(out))

      if repair == :correct do
        assert result["status"] == "converged"
        assert File.read!(Path.join(work, "executed-count")) == "3\n"
        assert result["qualification"]["verdicts"]["behavior"] == "fail"
      else
        refute result["status"] == "converged"
        refute File.exists?(Path.join(work, "executed-count"))
      end
    end
  end
end
