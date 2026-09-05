defmodule Kazi.Providers.ForbiddenCommandsTest do
  @moduledoc """
  ADR-0085: `[scope].forbidden_commands` — best-effort dispatch-transcript
  scanning. Explicitly a TRIPWIRE, not a sandbox (see the provider's
  moduledoc) — these tests pin the detection logic itself, not a claim of
  prevention.
  """
  use ExUnit.Case, async: true

  alias Kazi.Predicate
  alias Kazi.Providers.ForbiddenCommands

  describe "scan/2 — pure transcript scanning" do
    test "matches a Bash tool_use event whose command contains a forbidden pattern" do
      events = [
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Bash",
                "input" => %{"command" => "gh pr create --title x"}
              }
            ]
          }
        }
      ]

      assert [hit] = ForbiddenCommands.scan(events, ["gh pr create"])
      assert hit.pattern == "gh pr create"
    end

    test "matches case-insensitively" do
      events = [%{"type" => "text", "text" => "running GH PR CREATE now"}]
      assert [_hit] = ForbiddenCommands.scan(events, ["gh pr create"])
    end

    test "no match yields an empty list" do
      events = [%{"type" => "text", "text" => "git status"}]
      assert ForbiddenCommands.scan(events, ["gh pr create"]) == []
    end

    test "an empty pattern list never matches anything" do
      events = [%{"type" => "text", "text" => "gh pr create"}]
      assert ForbiddenCommands.scan(events, []) == []
    end

    test "an empty event list never matches anything" do
      assert ForbiddenCommands.scan([], ["gh pr create"]) == []
    end
  end

  describe "evaluate/2 — the predicate provider" do
    test "passes (never fails) with no transcript_path configured — advisory, not blocking" do
      predicate =
        Predicate.new(:scope_forbidden_commands, :forbidden_commands,
          config: %{forbidden_commands: ["gh pr create"]}
        )

      result = ForbiddenCommands.evaluate(predicate, %{})
      assert result.status == :pass
      assert result.evidence.scanned == false
    end

    test "passes with no transcript file present on disk" do
      predicate =
        Predicate.new(:scope_forbidden_commands, :forbidden_commands,
          config: %{forbidden_commands: ["gh pr create"]}
        )

      result = ForbiddenCommands.evaluate(predicate, %{transcript_path: "/nonexistent/x.jsonl"})
      assert result.status == :pass
      assert result.evidence.scanned == false
    end

    test "fails when the transcript contains a forbidden command attempt" do
      path = transcript_fixture([%{"type" => "text", "text" => "$ gh pr create --title y"}])

      predicate =
        Predicate.new(:scope_forbidden_commands, :forbidden_commands,
          config: %{forbidden_commands: ["gh pr create"]}
        )

      result = ForbiddenCommands.evaluate(predicate, %{transcript_path: path})
      assert result.status == :fail
      assert result.evidence.reason == :forbidden_command_attempted
      assert [%{pattern: "gh pr create"}] = result.evidence.hits
    end

    test "passes when the transcript is clean" do
      path = transcript_fixture([%{"type" => "text", "text" => "git status"}])

      predicate =
        Predicate.new(:scope_forbidden_commands, :forbidden_commands,
          config: %{forbidden_commands: ["gh pr create"]}
        )

      result = ForbiddenCommands.evaluate(predicate, %{transcript_path: path})
      assert result.status == :pass
      assert result.evidence.hits == []
    end
  end

  defp transcript_fixture(events) do
    dir =
      Path.join(System.tmp_dir!(), "kazi-fc-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "transcript.jsonl")
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
    path
  end
end
