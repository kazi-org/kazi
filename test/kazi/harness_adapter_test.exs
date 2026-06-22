defmodule Kazi.HarnessAdapterTest do
  use ExUnit.Case, async: true

  # Test-only adapter proving the @callback contract is usable. The real
  # `claude -p` adapter (T0.6) lives in lib/ in its own task and tests against a
  # stub binary; nothing concrete belongs in lib/ for this contract.
  defmodule StubAdapter do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run("", _workspace, _opts), do: {:error, :empty_prompt}

    def run(prompt, workspace, opts) do
      {:ok,
       %{
         output: "ran: #{prompt}",
         workspace: workspace,
         model: Keyword.get(opts, :model, :default),
         cost: %{tokens: 1234}
       }}
    end
  end

  test "behaviour declares run/3" do
    assert {:run, 3} in Kazi.HarnessAdapter.behaviour_info(:callbacks)
  end

  test "a conforming impl runs in the given workspace and captures output + cost" do
    assert {:ok, result} = StubAdapter.run("fix the failing test", "/tmp/ws", model: :opus)
    assert result.output == "ran: fix the failing test"
    assert result.workspace == "/tmp/ws"
    assert result.model == :opus
    assert result.cost == %{tokens: 1234}
  end

  test "impl can signal failure to run the harness" do
    assert {:error, :empty_prompt} = StubAdapter.run("", "/tmp/ws", [])
  end
end
