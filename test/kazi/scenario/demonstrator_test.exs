defmodule Kazi.Scenario.DemonstratorTest do
  # Tier 2: the born-reproducible acceptance gate is REAL — it runs the genuine
  # T49.1 validator + T49.3 replay path (browser delegate stubbed via the shipped
  # stub_playwright.sh, exactly as the provider tests). Only the demonstrator
  # HARNESS is a stub, the established Adopt.enrich injection seam (T49.7, ADR-0064).
  use ExUnit.Case, async: true

  alias Kazi.Predicate
  alias Kazi.Scenario.{Demonstrator, Source}

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  @feature """
  Feature: Greeting

    Scenario: A visitor sees the greeting
      Given the greeting page is open
      Then the greeting is shown
  """
  @scenario_name "A visitor sees the greeting"
  @url "https://example.test/greeting"

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_demo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    spec = Path.join(dir, "greeting.feature")
    File.write!(spec, @feature)
    pin = Path.join(dir, "greeting.pin.json")

    {:ok, ws: dir, spec: spec, pin: pin}
  end

  defp scenario_sha do
    {:ok, scenario} = Source.extract(@feature, @scenario_name)
    Source.sha(scenario)
  end

  defp valid_pin(spec) do
    %{
      "pin_version" => 1,
      "spec" => spec,
      "scenario" => @scenario_name,
      "scenario_sha" => scenario_sha(),
      "surface" => "browser",
      "inputs" => %{},
      "trace" => %{
        "url" => @url,
        "steps" => [],
        "assertions" => [%{"type" => "visible", "selector" => "#greeting"}]
      },
      "map" => [%{"step" => "the greeting is shown", "steps" => [], "assertions" => [0]}]
    }
  end

  # A vacuous pin: the Then step maps to ZERO assertions (fails the T49.1 floor).
  defp vacuous_pin(spec) do
    valid_pin(spec)
    |> Map.put("map", [%{"step" => "the greeting is shown", "steps" => [], "assertions" => []}])
  end

  defp green_verdict do
    Jason.encode!(%{
      status: "pass",
      url: @url,
      assertions: [%{type: "visible", selector: "#greeting", ok: true}],
      screenshot: nil,
      error: nil
    })
  end

  defp predicate(spec, pin) do
    Predicate.new("cap", :scenario,
      config: %{
        spec: spec,
        scenario: @scenario_name,
        pin: pin,
        surface: "browser",
        cmd: @stub,
        args: [],
        env: [{"STUB_JSON", green_verdict()}]
      }
    )
  end

  # A stub harness that writes `pin_json` (from adapter_opts) to `pin_path` — the
  # demonstrator "operating the surface and minting the pin".
  defmodule PinWritingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, opts) do
      File.write!(Keyword.fetch!(opts, :pin_path), Keyword.fetch!(opts, :pin_json))
      {:ok, %{output: "minted", cost: %{tokens: 3}}}
    end
  end

  defmodule PromptCapturingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(prompt, _workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:prompt, prompt})
      {:ok, %{output: "", cost: %{tokens: 0}}}
    end
  end

  defmodule CrashingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: raise("harness boom")
  end

  defmodule ErroringHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:error, :unavailable}
  end

  defp demonstrate(spec, pin, ws, harness, adapter_opts) do
    Demonstrator.demonstrate(predicate(spec, pin), %{workspace: ws},
      harness: harness,
      adapter_opts: adapter_opts
    )
  end

  test "a pin that validates AND replays green is ACCEPTED and kept", %{
    ws: ws,
    spec: spec,
    pin: pin
  } do
    opts = [pin_path: pin, pin_json: Jason.encode!(valid_pin(spec))]

    assert {:accepted, info} = demonstrate(spec, pin, ws, PinWritingHarness, opts)
    assert info.result.status == :pass
    assert File.exists?(pin)
  end

  test "a vacuous pin (unmapped Then) is REJECTED and the file discarded", %{
    ws: ws,
    spec: spec,
    pin: pin
  } do
    opts = [pin_path: pin, pin_json: Jason.encode!(vacuous_pin(spec))]

    assert {:rejected, info} = demonstrate(spec, pin, ws, PinWritingHarness, opts)
    assert info.demonstration == :rejected
    assert Enum.any?(info.reasons, &match?({:unmapped_then, _}, &1))
    # The write is discarded, so the predicate stays honestly unpinned.
    refute File.exists?(pin)
  end

  test "a crashing harness leaves no pin and does not propagate", %{ws: ws, spec: spec, pin: pin} do
    assert {:error, info} = demonstrate(spec, pin, ws, CrashingHarness, [])
    assert info.demonstration == :error
    refute File.exists?(pin)
  end

  test "a harness that errors is a rejected/error demonstration, pin discarded", %{
    ws: ws,
    spec: spec,
    pin: pin
  } do
    assert {:error, info} = demonstrate(spec, pin, ws, ErroringHarness, [])
    assert info.demonstration == :error
    refute File.exists?(pin)
  end

  test "the prompt is byte-identical across two dispatches of the same scenario", %{
    ws: ws,
    spec: spec,
    pin: pin
  } do
    demonstrate(spec, pin, ws, PromptCapturingHarness, collector: self())
    assert_received {:prompt, first}

    demonstrate(spec, pin, ws, PromptCapturingHarness, collector: self())
    assert_received {:prompt, second}

    assert first == second
    assert first =~ "v#{Demonstrator.prompt_version()}"
    assert first =~ @scenario_name
    # The write-only-the-pin constraint is stated explicitly.
    assert first =~ pin
    assert first =~ "ONLY the pin"
  end
end
