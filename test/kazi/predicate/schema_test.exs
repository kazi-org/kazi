defmodule Kazi.Predicate.SchemaTest do
  @moduledoc """
  T32.1 (ADR-0040 decision 6): `kazi schema custom_script` self-describes every
  config key the generic command-runner accepts, so an agent can introspect it at
  runtime with no external docs.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.Predicate.Schema

  # Every key the custom_script provider accepts must appear in its schema.
  @expected_keys ~w(cmd args env verdict pass_codes fail_codes path match_regex pass_when
                    merge_stderr error_codes evidence_format timeout_ms)

  test "the custom_script schema lists EVERY config key" do
    {:ok, schema} = Schema.fetch("custom_script")
    listed = schema.keys |> Enum.map(& &1.name) |> MapSet.new()

    assert MapSet.equal?(listed, MapSet.new(@expected_keys)),
           "schema keys drifted: #{inspect(listed)}"
  end

  test "every key descriptor is fully documented (name/type/required/description)" do
    {:ok, schema} = Schema.fetch("custom_script")

    for key <- schema.keys do
      assert is_binary(key.name) and key.name != ""
      assert is_binary(key.type) and key.type != ""
      assert is_boolean(key.required)
      assert is_binary(key.description) and key.description != ""
    end
  end

  test "fetch/1 returns :error for an unknown kind" do
    assert Schema.fetch("not_a_provider") == :error
  end

  describe "live provider schemas (T32.10, ADR-0043)" do
    for kind <- ~w(http_probe browser metrics) do
      test "#{kind} has a fully-documented config schema" do
        {:ok, schema} = Schema.fetch(unquote(kind))
        assert schema.kind == unquote(kind)
        assert schema.description != ""

        for key <- schema.keys do
          assert key.name != ""
          assert key.type != ""
          assert is_boolean(key.required)
          assert key.description != ""
        end
      end
    end

    test "kinds/0 lists every provider schema, sorted" do
      kinds = Schema.kinds()
      assert kinds == Enum.sort(kinds)
      assert MapSet.subset?(MapSet.new(~w(http_probe browser metrics)), MapSet.new(kinds))
    end

    test "the http_probe schema documents sustained-health samples" do
      {:ok, schema} = Schema.fetch("http_probe")
      names = schema.keys |> Enum.map(& &1.name) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(~w(samples interval_ms)), names)
    end

    test "the metrics schema documents the three modes' keys" do
      {:ok, schema} = Schema.fetch("metrics")
      names = schema.keys |> Enum.map(& &1.name) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(~w(query_url query pass_when quantile burn_rate)), names)
    end

    test "kazi schema metrics emits the key schema as JSON and exits 0" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "metrics"]) == 0 end)
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["kind"] == "metrics"
    end

    # A goal author reaches the assertion vocabulary through `kazi schema browser`
    # — it is the only place the types are enumerated at the CLI (T43.1, ADR-0053).
    test "the browser schema documents every runner assertion type" do
      {:ok, schema} = Schema.fetch("browser")
      assert %{description: description} = Enum.find(schema.keys, &(&1.name == "assertions"))

      for type <- ~w(visible hidden text url console_clean) do
        assert description =~ type, "kazi schema browser must document the #{type} assertion"
      end
    end

    test "kazi schema browser lists console_clean and its network flag" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "browser"]) == 0 end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["kind"] == "browser"

      assertions = Enum.find(payload["keys"], &(&1["name"] == "assertions"))
      assert assertions["description"] =~ "console_clean"
      assert assertions["description"] =~ "network"
      assert assertions["description"] =~ "console.error"
    end
  end

  describe "kazi schema custom_script (CLI)" do
    test "emits the custom_script key schema as JSON and exits 0" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "custom_script"]) == 0 end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["kind"] == "custom_script"
      key_names = payload["keys"] |> Enum.map(& &1["name"]) |> MapSet.new()
      assert MapSet.equal?(key_names, MapSet.new(@expected_keys))
    end

    test "an unknown schema key still reports 'no result schema' (non-zero exit)" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "not-a-thing"]) == 1 end)
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "no result schema"
      # The error now also lists the available provider schemas.
      assert payload["error"] =~ "custom_script"
    end
  end
end
