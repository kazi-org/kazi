defmodule Kazi.CLI.DispatchContractTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    root = Path.join(System.tmp_dir!(), "kazi-dispatch-contract-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q", root])
    File.write!(Path.join(root, "guard"), "kept\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  for entry <- [:file, :proposal], tier <- [0, 1], described <- [true, false] do
    test "#{entry} tier #{tier} described=#{described} preserves the public task over two launches",
         %{root: root} do
      brief =
        if unquote(described),
          do: "BRIEF_START " <> String.duplicate("required detail ", 2_000) <> " BRIEF_END",
          else: nil

      payload = %{
        "goal_id" => "dispatch-contract-#{Ecto.UUID.generate()}",
        "name" => "PUBLIC_NAME_SENTINEL",
        "description" => "PUBLIC_DESCRIPTION_SENTINEL",
        "scope" => %{
          "paths" => ["reference.txt"],
          "write_paths" => ["app.sh"],
          "no_integration" => true
        },
        "budget" => %{"max_total_dispatches" => 2},
        "enforcement" => %{"enabled" => false},
        "predicates" => [
          %{
            "id" => "brief",
            "provider" => "custom_script",
            "description" => brief,
            "config" => %{
              "cmd" => "sh",
              "args" => ["-c", "test -f first"],
              "verdict" => "exit_zero"
            }
          },
          %{
            "id" => "code",
            "provider" => "custom_script",
            "description" => "CODE_SENTINEL test/widget_test.exs",
            "config" => %{
              "cmd" => "sh",
              "args" => ["-c", "test -f done"],
              "verdict" => "exit_zero"
            }
          },
          %{
            "id" => "guard",
            "provider" => "custom_script",
            "guard" => true,
            "description" => "GUARD_SENTINEL",
            "config" => %{
              "cmd" => "sh",
              "args" => ["-c", "test -f guard"],
              "verdict" => "exit_zero"
            }
          },
          %{
            "id" => "hidden",
            "provider" => "custom_script",
            "held_out" => true,
            "description" => "HIDDEN_SENTINEL",
            "config" => %{"cmd" => "sh", "args" => ["-c", "true"], "verdict" => "exit_zero"}
          }
        ]
      }

      ref =
        if unquote(entry) == :proposal do
          proposed = json_cli(["plan", "--json", "--predicates", Jason.encode!(payload)])
          ref = proposed["proposal_ref"]
          assert json_cli(["approve", ref, "--json"])["status"] == "approved"
          ref
        else
          path = Path.join(root, "goal.toml")
          File.write!(path, goal_toml(payload))
          path
        end

      worker = Kazi.Test.DispatchContractHarness.write!(root)

      result =
        json_cli(
          [
            "apply",
            ref,
            "--workspace",
            root,
            "--in-place",
            "--allow-primary-workspace",
            "--json"
          ],
          adapter_opts: [command: worker, context_tier: unquote(tier), token_budget: 16],
          sinks_dir: Path.join(root, "sinks"),
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )

      assert result["status"] == "converged"
      assert File.read!(Path.join(root, "count")) == "2\n"
      prompts = for n <- [1, 2], do: File.read!(Path.join(root, "prompt.#{n}"))

      for prompt <- prompts do
        for required <- [
              "PUBLIC_NAME_SENTINEL",
              "PUBLIC_DESCRIPTION_SENTINEL",
              "CODE_SENTINEL",
              "test/widget_test.exs",
              "GUARD_SENTINEL",
              "test -f first",
              "test -f done",
              "Read paths: [\"reference.txt\"]",
              "Write paths: [\"app.sh\"]"
            ] do
          assert prompt =~ required
        end

        if brief, do: assert(prompt =~ brief), else: refute(prompt =~ "BRIEF_START")
        refute prompt =~ "HIDDEN_SENTINEL"
      end

      assert Enum.at(prompts, 1) =~ "fix failing predicates: code"
    end
  end

  defp json_cli(args, opts \\ []) do
    output = capture_io(fn -> assert Kazi.CLI.run(args, opts) == 0 end)
    result = Jason.decode!(String.trim(output))
    assert result["schema_version"] == 2
    result
  end

  defp goal_toml(payload) do
    """
    id = #{Jason.encode!(payload["goal_id"])}
    name = "PUBLIC_NAME_SENTINEL"
    description = "PUBLIC_DESCRIPTION_SENTINEL"
    mode = "create"
    [scope]
    paths = ["reference.txt"]
    write_paths = ["app.sh"]
    no_integration = true
    [budget]
    max_total_dispatches = 2
    [enforcement]
    enabled = false
    """ <>
      Enum.map_join(payload["predicates"], "\n", fn p ->
        "\n[[predicate]]\n" <>
          Enum.map_join(Map.merge(Map.drop(p, ["config"]), p["config"]), "\n", fn
            {_, nil} -> ""
            {key, value} -> "#{key} = #{Jason.encode!(value)}"
          end)
      end)
  end
end
