defmodule Kazi.Scenario.DemonstratorRepinTest do
  # Tier 2 (T49.8): the acceptance write path stamps the minted commit (real git)
  # and a REPIN carries the old->new unified diff. Real T49.1 validate + T49.3
  # replay (browser stubbed), only the harness is a stub.
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

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_demo_repin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "t@example.test"])
    git(dir, ["config", "user.name", "kazi test"])

    spec = Path.join(dir, "greeting.feature")
    File.write!(spec, @feature)
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "init"])
    {head, 0} = git(dir, ["rev-parse", "HEAD"])

    pin = Path.join(dir, "greeting.pin.json")
    {:ok, dir: dir, spec: spec, pin: pin, head: String.trim(head)}
  end

  defp scenario_sha do
    {:ok, scenario} = Source.extract(@feature, @scenario_name)
    Source.sha(scenario)
  end

  defp pin_json(spec, selector) do
    Jason.encode!(%{
      "pin_version" => 1,
      "spec" => spec,
      "scenario" => @scenario_name,
      "scenario_sha" => scenario_sha(),
      "surface" => "browser",
      "inputs" => %{},
      "trace" => %{
        "url" => @url,
        "steps" => [],
        "assertions" => [%{"type" => "visible", "selector" => selector}]
      },
      "map" => [%{"step" => "the greeting is shown", "steps" => [], "assertions" => [0]}]
    })
  end

  defp green_verdict do
    Jason.encode!(%{status: "pass", url: @url, assertions: [], screenshot: nil, error: nil})
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

  defmodule PinWritingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, opts) do
      File.write!(Keyword.fetch!(opts, :pin_path), Keyword.fetch!(opts, :pin_json))
      {:ok, %{output: "minted", cost: %{tokens: 1}}}
    end
  end

  defp demonstrate(spec, pin, dir, adapter_opts) do
    Demonstrator.demonstrate(predicate(spec, pin), %{workspace: dir},
      harness: PinWritingHarness,
      adapter_opts: adapter_opts
    )
  end

  test "an accepted pin is stamped with minted.commit = HEAD", %{
    dir: dir,
    spec: spec,
    pin: pin,
    head: head
  } do
    assert {:accepted, _info} =
             demonstrate(spec, pin, dir, pin_path: pin, pin_json: pin_json(spec, "#greeting"))

    {:ok, stamped} = File.read(pin)
    assert %{"minted" => %{"commit" => ^head}} = Jason.decode!(stamped)
  end

  test "a REPIN carries the old->new unified diff in evidence", %{dir: dir, spec: spec, pin: pin} do
    # An OLD pin already exists (a stale one being re-demonstrated).
    File.write!(pin, pin_json(spec, "#old-selector"))

    assert {:accepted, info} =
             demonstrate(spec, pin, dir, pin_path: pin, pin_json: pin_json(spec, "#greeting"))

    assert is_binary(info.repin_diff)
    # The diff shows the old selector removed and the new one added.
    assert info.repin_diff =~ "#old-selector"
    assert info.repin_diff =~ "#greeting"
    assert info.repin_diff =~ ~r/^- /m
    assert info.repin_diff =~ ~r/^\+ /m
  end

  test "a fresh mint (no prior pin) carries no repin_diff", %{dir: dir, spec: spec, pin: pin} do
    assert {:accepted, info} =
             demonstrate(spec, pin, dir, pin_path: pin, pin_json: pin_json(spec, "#greeting"))

    refute Map.has_key?(info, :repin_diff)
  end
end
