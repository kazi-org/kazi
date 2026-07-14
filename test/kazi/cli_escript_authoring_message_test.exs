defmodule Kazi.CLIEscriptAuthoringMessageTest do
  use ExUnit.Case, async: true

  # T39.5 (ADR-0049): the escript cannot bundle the SQLite NIF, so authoring
  # (`plan`/`approve`/`reject`/`list-proposed`) refuses when the read-model is
  # unavailable. That refusal must GUIDE, not just fail: the message names the
  # supported entrypoints (release binary / `mix`), and `kazi help` states the
  # same limitation up front.
  #
  # A live repro requires the read-model genuinely unavailable, which only
  # happens when the SQLite NIF fails to load (the escript build) -- not safely
  # simulable inside `mix test` without corrupting the suite's shared
  # connection. Like the L2 deep-review guard, this is a deterministic
  # source-level pin of the user-facing strings.

  @cli_source File.read!(Path.join([File.cwd!(), "lib", "kazi", "cli.ex"]))

  describe "T39.5: escript authoring refusal names the supported entrypoint" do
    test "the read-model-unavailable message names the release binary and mix" do
      assert @cli_source =~ "the read-model is unavailable; authoring requires persistence"

      assert @cli_source =~ "release binary",
             "the refusal must name the release binary as a supported entrypoint"

      assert @cli_source =~ "mix run",
             "the refusal must name the mix path as a supported entrypoint"

      assert @cli_source =~ "SQLite NIF",
             "the refusal must state WHY the escript cannot author"
    end

    test "kazi help states the authoring entrypoint limitation" do
      assert @cli_source =~ "escript build lacks the SQLite NIF",
             "the help text must carry the authoring-entrypoint note"
    end
  end
end
