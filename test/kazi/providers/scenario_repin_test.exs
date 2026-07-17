defmodule Kazi.Providers.ScenarioRepinTest do
  # Tier 2: the repin re-classification (T49.8) is REAL — a genuine git workspace
  # (HEAD moved vs at the minted commit) and the genuine browser replay path,
  # stubbed via stub_playwright.sh so a RED replay is deterministic.
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Scenario
  alias Kazi.Scenario.Source

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

  defp head(dir) do
    {out, 0} = git(dir, ["rev-parse", "HEAD"])
    String.trim(out)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_repin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "t@example.test"])
    git(dir, ["config", "user.name", "kazi test"])

    spec = Path.join(dir, "greeting.feature")
    File.write!(spec, @feature)
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "init"])

    pin = Path.join(dir, "greeting.pin.json")

    {:ok, dir: dir, spec: spec, pin: pin, minted: head(dir)}
  end

  defp scenario_sha do
    {:ok, scenario} = Source.extract(@feature, @scenario_name)
    Source.sha(scenario)
  end

  defp write_pin!(pin, spec, opts) do
    json = %{
      "pin_version" => 1,
      "spec" => spec,
      "scenario" => @scenario_name,
      "scenario_sha" => Keyword.get(opts, :sha, scenario_sha()),
      "surface" => "browser",
      "minted" => %{"commit" => Keyword.fetch!(opts, :minted)},
      "inputs" => %{},
      "trace" => %{
        "url" => @url,
        "steps" => [],
        "assertions" => [%{"type" => "visible", "selector" => "#greeting"}]
      },
      "map" => [%{"step" => "the greeting is shown", "steps" => [], "assertions" => [0]}]
    }

    File.write!(pin, Jason.encode!(json))
  end

  defp red_verdict do
    Jason.encode!(%{
      status: "fail",
      url: @url,
      assertions: [
        %{type: "visible", selector: "#greeting", ok: false, expected: "visible", found: "hidden"}
      ],
      screenshot: nil,
      error: nil
    })
  end

  defp evaluate(spec, pin, dir, repin \\ "auto") do
    predicate =
      Predicate.new("cap", :scenario,
        config: %{
          spec: spec,
          scenario: @scenario_name,
          pin: pin,
          surface: "browser",
          repin: repin,
          cmd: @stub,
          args: [],
          env: [{"STUB_JSON", red_verdict()}]
        }
      )

    Scenario.evaluate(predicate, %{workspace: dir})
  end

  test "a RED replay at the minted commit stays a plain :pinned :fail (a regression -> fixer)", %{
    dir: dir,
    spec: spec,
    pin: pin,
    minted: minted
  } do
    write_pin!(pin, spec, minted: minted)

    result = evaluate(spec, pin, dir)

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.pin_state == :pinned
  end

  test "a RED replay with a MOVED HEAD is re-classified {:stale, :code_drift} (-> demonstrator)",
       %{dir: dir, spec: spec, pin: pin, minted: minted} do
    write_pin!(pin, spec, minted: minted)
    # Move HEAD past the minted commit — the code drifted.
    File.write!(Path.join(dir, "code.txt"), "changed")
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "drift"])

    result = evaluate(spec, pin, dir)

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.pin_state == {:stale, :code_drift}
  end

  test "repin=manual parks code drift as :stale_manual (never auto-demonstrated)", %{
    dir: dir,
    spec: spec,
    pin: pin,
    minted: minted
  } do
    write_pin!(pin, spec, minted: minted)
    File.write!(Path.join(dir, "code.txt"), "changed")
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "drift"])

    result = evaluate(spec, pin, dir, "manual")

    assert result.evidence.pin_state == :stale_manual
  end

  test "a spec_changed stale pin parks as :stale_manual under repin=manual", %{
    dir: dir,
    spec: spec,
    pin: pin,
    minted: minted
  } do
    write_pin!(pin, spec, minted: minted, sha: String.duplicate("b", 64))

    result = evaluate(spec, pin, dir, "manual")

    assert result.evidence.pin_state == :stale_manual
  end

  test "a spec_changed stale pin stays {:stale, :spec_changed} under repin=auto", %{
    dir: dir,
    spec: spec,
    pin: pin,
    minted: minted
  } do
    write_pin!(pin, spec, minted: minted, sha: String.duplicate("b", 64))

    result = evaluate(spec, pin, dir, "auto")

    assert result.evidence.pin_state == {:stale, :spec_changed}
  end
end
