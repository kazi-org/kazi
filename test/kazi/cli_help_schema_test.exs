defmodule Kazi.CLIHelpSchemaTest do
  @moduledoc """
  T16.1 (ADR-0024 decision 2): `kazi help --json` + `kazi schema` — kazi
  self-describes to harnesses so any agent can introspect it at runtime.

  Tier 1 pins the argv boundary: `help` / `schema` parse into the right command
  tuples, carrying `--json` and the optional positional.

  Tier 2 drives the real CLI exec core (`Kazi.CLI.run/2`) through
  `ExUnit.CaptureIO` and asserts the emitted JSON:

    * `help --json` lists EVERY command + its flags, and stays in sync with the
      real command table (it is GENERATED from the same `@commands`/`@switches`
      the parser reads — adding a command/flag updates it automatically). The test
      pins this by deriving the expected command set from `Kazi.CLI.parse/1`'s own
      behaviour: every command name `help --json` reports must be a command the
      parser dispatches (not the unknown-command error), and vice versa.
    * `schema run` / `schema status` return the documented result schema with
      `schema_version`; both parse; the shapes match the committed contracts.
    * both are non-interactive + JSON-only (no stdin read, no human prose mixed in).

  HERMETIC: no real `claude`, no network, no read-model needed (help/schema are
  pure reads of in-process data).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # ===========================================================================
  # Tier 1 — argv boundary
  # ===========================================================================

  describe "parse/1 — help / schema commands" do
    test "`help` parses to the help command, defaulting json to false" do
      assert {:help, opts} = Kazi.CLI.parse(["help"])
      assert opts[:json] == false
    end

    test "`help --json` carries the json flag" do
      assert {:help, opts} = Kazi.CLI.parse(["help", "--json"])
      assert opts[:json] == true
    end

    test "the leading `--help` flag still parses to help (back-compat)" do
      assert {:help, flags} = Kazi.CLI.parse(["--help"])
      # The raw OptionParser flags: absent --json reads as nil (human is default).
      refute flags[:json] == true
    end

    test "`schema` with no command parses to a nil-command schema request" do
      assert {:schema, nil, _opts} = Kazi.CLI.parse(["schema"])
    end

    test "`schema apply` carries the positional command" do
      assert {:schema, "apply", _opts} = Kazi.CLI.parse(["schema", "apply"])
    end

    test "`schema` rejects extra positionals" do
      assert {:error, message} = Kazi.CLI.parse(["schema", "apply", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — help --json (the generated command/flag surface)
  # ===========================================================================

  describe "run/2 — help --json" do
    test "emits a single JSON object (no human prose) and exits 0" do
      out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert is_map(payload)
      assert payload["schema_version"] == 2
      assert payload["kazi"] =~ ~r/^\d+\.\d+\.\d+/
      # JSON-only: the human usage prose is NOT interleaved.
      refute out =~ "USAGE:"
    end

    test "lists every command the parser dispatches (stays in sync with the real table)" do
      out = capture_io(fn -> Kazi.CLI.run(["help", "--json"]) end)
      {:ok, payload} = Jason.decode(String.trim(out))

      reported = payload["commands"] |> Enum.map(& &1["name"]) |> MapSet.new()

      # The drift guard: every command `help --json` reports must be one the parser
      # actually dispatches (parse/1 does NOT return an unknown-command error for
      # it), and the known commands must all be reported. This is what makes the
      # surface "generated, not hand-maintained" (ADR-0024).
      # T27.9 (ADR-0032): `apply`/`plan` are the ONLY verbs; the `run`/`propose`
      # aliases were removed in v0.6.0, so the table (and help --json) omits them.
      expected =
        MapSet.new(
          ~w(apply status init install-skill mcp dashboard economy plan list-proposed approve reject export lint context memory help schema version)
        )

      assert reported == expected,
             "help --json command set drifted: missing #{inspect(MapSet.difference(expected, reported))}, extra #{inspect(MapSet.difference(reported, expected))}"

      for name <- expected do
        refute match?({:error, _}, dispatch_probe(name)),
               "help --json reports #{name} but the parser does not dispatch it"
      end
    end

    test "apply/plan are the only verbs; run/propose are absent (T27.9, ADR-0032)" do
      out = capture_io(fn -> Kazi.CLI.run(["help", "--json"]) end)
      {:ok, payload} = Jason.decode(String.trim(out))

      by_name = Map.new(payload["commands"], &{&1["name"], &1})

      # The verbs are not deprecated and carry no alias_of.
      for verb <- ~w(apply plan status init) do
        cmd = by_name[verb]
        assert cmd["deprecated"] == false, "#{verb} should be a (non-deprecated) verb"
        refute Map.has_key?(cmd, "alias_of"), "#{verb} should not carry alias_of"
      end

      # The removed `run`/`propose` aliases (T27.9) are no longer in the surface.
      refute Map.has_key?(by_name, "run")
      refute Map.has_key?(by_name, "propose")

      # Every command object still carries the boolean `deprecated` field (generated
      # from the table); with no aliases left, all are false.
      for cmd <- payload["commands"] do
        assert is_boolean(cmd["deprecated"])
        assert cmd["deprecated"] == false
      end
    end

    test "each command lists its flags with name/type/description, derived from the parser table" do
      out = capture_io(fn -> Kazi.CLI.run(["help", "--json"]) end)
      {:ok, payload} = Jason.decode(String.trim(out))

      apply_cmd = Enum.find(payload["commands"], &(&1["name"] == "apply"))
      flag_names = Enum.map(apply_cmd["flags"], & &1["name"])

      # `apply` accepts these flags in the real switch table; help --json reports them.
      assert "--workspace" in flag_names
      assert "--json" in flag_names
      assert "--stream" in flag_names

      for flag <- apply_cmd["flags"] do
        assert is_binary(flag["name"]) and String.starts_with?(flag["name"], "--")
        assert flag["type"] in ["string", "boolean", "integer"]
        assert is_binary(flag["description"]) and flag["description"] != ""
        assert is_list(flag["aliases"])
      end
    end

    test "every command + flag in the surface is documented (no blank descriptions)" do
      out = capture_io(fn -> Kazi.CLI.run(["help", "--json"]) end)
      {:ok, payload} = Jason.decode(String.trim(out))

      for command <- payload["commands"] do
        assert is_binary(command["summary"]) and command["summary"] != ""
        assert is_list(command["args"])

        for arg <- command["args"] do
          assert is_binary(arg["name"])
          assert is_boolean(arg["required"])
        end

        for flag <- command["flags"] do
          assert is_binary(flag["description"]) and flag["description"] != ""
        end
      end
    end

    test "without --json the human usage is unchanged (JSON is opt-in)" do
      out = capture_io(fn -> assert Kazi.CLI.run(["help"]) == 0 end)
      assert out =~ "USAGE:"
      assert {:error, _} = Jason.decode(String.trim(out))
    end
  end

  # ===========================================================================
  # Tier 2 — schema [<command>] (the versioned result schemas)
  # ===========================================================================

  describe "run/2 — schema" do
    test "schema apply returns the (former run) result schema with schema_version; parses" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "apply"]) == 0 end)

      assert {:ok, schema} = Jason.decode(String.trim(out))
      assert schema["schema_version"] == 2
      assert schema["command"] == "apply"
      # The documented apply-result fields are present in the descriptor.
      field_names = schema["fields"] |> Enum.map(& &1["name"]) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(~w(status predicates iterations next_action)), field_names)
      # The example object carries the same schema_version (the contract pin).
      assert schema["example"]["schema_version"] == 2
      assert schema["example"]["status"] == "converged"
    end

    test "schema plan returns the (former propose) authoring schema; parses" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "plan"]) == 0 end)

      assert {:ok, schema} = Jason.decode(String.trim(out))
      assert schema["schema_version"] == 2
      assert schema["command"] == "plan"
      field_names = schema["fields"] |> Enum.map(& &1["name"]) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(~w(proposal_ref goal_id predicates clarify)), field_names)
    end

    test "schema run / schema propose NO LONGER resolve (removed in v0.6.0, T27.9)" do
      # The removed aliases now hit the unknown-command branch: a JSON error on
      # stdout with a non-zero exit, not the apply/plan schema.
      run_out = capture_io(fn -> assert Kazi.CLI.run(["schema", "run"]) == 1 end)
      assert {:ok, run_err} = Jason.decode(String.trim(run_out))
      assert run_err["error"] =~ "no result schema"

      propose_out = capture_io(fn -> assert Kazi.CLI.run(["schema", "propose"]) == 1 end)
      assert {:ok, propose_err} = Jason.decode(String.trim(propose_out))
      assert propose_err["error"] =~ "no result schema"
    end

    test "schema status returns the status schema with schema_version; parses" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "status"]) == 0 end)

      assert {:ok, schema} = Jason.decode(String.trim(out))
      assert schema["schema_version"] == 2
      assert schema["command"] == "status"
      field_names = schema["fields"] |> Enum.map(& &1["name"]) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(~w(kind ref status predicates)), field_names)
    end

    test "schema (no command) returns all schemas keyed by the primary command" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema"]) == 0 end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      # Keyed by the PRIMARY verbs (ADR-0032): apply/plan/status, not run/propose.
      assert Map.has_key?(payload["schemas"], "apply")
      assert Map.has_key?(payload["schemas"], "plan")
      assert Map.has_key?(payload["schemas"], "status")
      refute Map.has_key?(payload["schemas"], "run")
      refute Map.has_key?(payload["schemas"], "propose")
      assert payload["schemas"]["apply"]["schema_version"] == 2
    end

    test "an unknown command is a JSON error on stdout with a non-zero exit" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "does-not-exist"]) == 1 end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "no result schema"
      # JSON-only error surface (parses); no human prose.
      refute out =~ "error:"
    end

    test "schema is JSON-only and never reads stdin (non-interactive)" do
      # Captured with NO stdin supplied; it must complete without blocking.
      out =
        capture_io("", fn ->
          assert Kazi.CLI.run(["schema", "apply"]) == 0
        end)

      assert {:ok, _} = Jason.decode(String.trim(out))
    end
  end

  # The schema version the CLI emits matches the schema-as-data module's version
  # (the one number an orchestrator pins, kept in lockstep).
  test "the emitted schema_version matches Kazi.CLI.Schema.schema_version/0" do
    out = capture_io(fn -> Kazi.CLI.run(["schema", "apply"]) end)
    {:ok, schema} = Jason.decode(String.trim(out))
    assert schema["schema_version"] == Kazi.CLI.Schema.schema_version()
  end

  # Probe the parser for a single positional command name, supplying a dummy
  # positional arg where the command requires one, so we observe dispatch (not a
  # "missing argument" error). Returns the parse result.
  defp dispatch_probe(name) do
    argv =
      case name do
        n when n in ~w(apply init status approve reject plan export lint) ->
          [n, "dummy"]

        n when n in ~w(schema) ->
          [n, "apply"]

        # `context` requires a <subcommand> positional; probe with a real one
        # (`stats`) so we observe dispatch, not the missing-subcommand error.
        "context" ->
          ["context", "stats"]

        # `memory` requires a <subcommand> positional; probe with the real one
        # (`recall`, which itself needs a <query> — supply a dummy one too so we
        # observe dispatch, not a missing-argument error, ADR-0062).
        "memory" ->
          ["memory", "recall", "dummy"]

        # `economy` requires --rediscovery <goal> (no positional); probe with
        # it so we observe dispatch, not the missing-flag error (T48.10).
        "economy" ->
          ["economy", "--rediscovery", "dummy"]

        n ->
          [n]
      end

    Kazi.CLI.parse(argv)
  end
end
