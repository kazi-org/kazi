defmodule Kazi.Goal.SetupLoaderTest do
  @moduledoc """
  ADR-0088 (#1642): the loader maps the optional `[setup]` table onto
  `Goal.setup`. Absent resolves to `nil` (no provisioning step declared —
  byte-identical to before this feature existed); the field-type guards fail
  loudly at load, matching the `[seal]`/`[enforcement]` precedent.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Setup}
  alias Kazi.Goal.Loader

  defp base_data(extra \\ %{}) do
    Map.merge(
      %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]},
      extra
    )
  end

  defp load(extra), do: Loader.from_map(base_data(extra))

  test "no [setup] table -> nil (no provisioning step declared)" do
    assert {:ok, %Goal{setup: nil}} = Loader.from_map(base_data())
  end

  test "commands + timeout_ms are parsed onto a %Setup{}" do
    assert {:ok, %Goal{setup: %Setup{} = setup}} =
             load(%{
               "setup" => %{
                 "commands" => ["mix deps.get", "mix compile"],
                 "timeout_ms" => 60_000
               }
             })

    assert setup.commands == ["mix deps.get", "mix compile"]
    assert setup.timeout_ms == 60_000
  end

  test "timeout_ms defaults to Kazi.Setup.default_timeout_ms/0 when absent" do
    assert {:ok, %Goal{setup: %Setup{timeout_ms: timeout_ms}}} =
             load(%{"setup" => %{"commands" => ["mix deps.get"]}})

    assert timeout_ms == Setup.default_timeout_ms()
  end

  test "commands is required" do
    assert {:error, msg} = load(%{"setup" => %{}})
    assert msg =~ "commands"
  end

  test "commands must be a non-empty list of non-empty strings" do
    assert {:error, msg} = load(%{"setup" => %{"commands" => []}})
    assert msg =~ "commands"

    assert {:error, msg2} = load(%{"setup" => %{"commands" => [1, 2]}})
    assert msg2 =~ "commands"

    assert {:error, msg3} = load(%{"setup" => %{"commands" => ["ok", ""]}})
    assert msg3 =~ "commands"

    assert {:error, msg4} = load(%{"setup" => %{"commands" => "mix deps.get"}})
    assert msg4 =~ "commands"
  end

  test "timeout_ms must be a positive integer" do
    assert {:error, msg} = load(%{"setup" => %{"commands" => ["x"], "timeout_ms" => 0}})
    assert msg =~ "timeout_ms"

    assert {:error, msg2} = load(%{"setup" => %{"commands" => ["x"], "timeout_ms" => -1}})
    assert msg2 =~ "timeout_ms"

    assert {:error, msg3} = load(%{"setup" => %{"commands" => ["x"], "timeout_ms" => "60000"}})
    assert msg3 =~ "timeout_ms"
  end

  test "a non-table [setup] fails loudly" do
    assert {:error, msg} = load(%{"setup" => "nope"})
    assert msg =~ "[setup] must be a table"
  end
end
