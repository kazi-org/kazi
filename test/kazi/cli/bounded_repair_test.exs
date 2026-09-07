defmodule Kazi.CLI.BoundedRepairTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    root = Path.join(System.tmp_dir!(), "kazi-bounded-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "public paths cap failed launches and allow second-attempt success with usable handoff", %{
    root: root
  } do
    for entry <- [:file, :proposal], fix <- [true, false] do
      work = Path.join(root, "#{entry}-#{fix}")
      File.mkdir_p!(work)
      script = Path.join(work, "worker.sh")

      File.write!(script, """
      #!/bin/sh
      n=$(cat count 2>/dev/null || echo 0)
      n=$((n+1))
      echo "$n" > count
      if test "$n" = 2 && test "#{fix}" = true; then touch fixed; fi
      if test "$n" = 1; then exit 1; fi
      exit 0
      """)

      File.chmod!(script, 0o755)

      payload = %{
        "goal_id" => "bounded-#{entry}-#{fix}",
        "name" => "preserve the complete repair contract",
        "predicates" => [
          %{
            "id" => "code",
            "provider" => "custom_script",
            "description" => "Create fixed after a real repair",
            "config" => %{
              "cmd" => "sh",
              "args" => ["-c", "test -f fixed"],
              "verdict" => "exit_zero"
            }
          }
        ],
        "budget" => %{"max_total_dispatches" => 2, "max_dispatches" => 1},
        "escalation" => %{"ladder" => ["one", "two", "three"]},
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
            id = "bounded-file-#{fix}"
            name = "preserve the complete repair contract"
            [budget]
            max_total_dispatches = 2
            max_dispatches = 1
            [escalation]
            ladder = ["one", "two", "three"]
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

      output =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"],
                   adapter_opts: [command: script],
                   sinks_dir: Path.join(root, "sinks"),
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == if(fix, do: 0, else: 1)
        end)

      result = Jason.decode!(String.trim(output))
      assert File.read!(Path.join(work, "count")) == "2\n"

      if fix do
        assert result["status"] == "converged"
      else
        assert result["status"] == "over_budget"
        assert result["budget_spent"]["exceeded"] == "max_total_dispatches"
        bundle = result["stuck_bundle"]
        handoff = bundle["handoff"]
        assert handoff["total_dispatches"] == 2
        assert handoff["failing_ids"] == ["code"]
        assert handoff["contract"]["status"] == "available"
        assert File.read!(handoff["contract"]["path"]) =~ "preserve the complete repair contract"
        assert File.regular?(handoff["verification"]["path"])
        assert byte_size(Kazi.Context.StuckBundle.render(bundle)) <= 12_000
      end
    end
  end
end
