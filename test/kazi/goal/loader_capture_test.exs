defmodule Kazi.Goal.LoaderCaptureTest do
  @moduledoc """
  ADR-0081 (#1521): loading the `[[capture]]` block into `Goal.captures`, and the
  render_proof predicate's load-time capture-reference validation.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader

  defp with_capture(extra_predicate \\ nil, capture_overrides \\ %{}) do
    capture =
      Map.merge(
        %{"name" => "now_screen", "launch_cmd" => "sh", "output" => "now_screen.png"},
        capture_overrides
      )

    predicates =
      [%{"id" => "p", "provider" => "http_probe", "url" => "https://example.test"}] ++
        List.wrap(extra_predicate)

    %{"id" => "g", "capture" => [capture], "predicate" => predicates}
  end

  test "a [[capture]] block parses into Goal.captures" do
    data =
      with_capture(nil, %{
        "launch_args" => ["scripts/shot.js", "--route", "/now"],
        "reset_cmd" => "xcrun",
        "reset_args" => ["simctl", "erase", "booted"],
        "post_launch_wait_ms" => 1500,
        "timeout_ms" => 30_000
      })

    assert {:ok, %Goal{captures: [capture]}} = Loader.from_map(data)
    assert capture.name == "now_screen"
    assert capture.launch_cmd == "sh"
    assert capture.launch_args == ["scripts/shot.js", "--route", "/now"]
    assert capture.reset_cmd == "xcrun"
    assert capture.reset_args == ["simctl", "erase", "booted"]
    assert capture.output == "now_screen.png"
    assert capture.post_launch_wait_ms == 1500
    assert capture.timeout_ms == 30_000
  end

  test "a goal with no [[capture]] block has empty captures (byte-identical default)" do
    data = %{
      "id" => "g",
      "predicate" => [%{"id" => "p", "provider" => "http_probe", "url" => "https://x.test"}]
    }

    assert {:ok, %Goal{captures: []}} = Loader.from_map(data)
  end

  test "a capture missing a required key fails at load" do
    data = with_capture(nil, %{"launch_cmd" => nil})
    data = put_in(data, ["capture"], [Map.delete(hd(data["capture"]), "launch_cmd")])

    assert {:error, reason} = Loader.from_map(data)
    assert reason =~ "launch_cmd"
  end

  test "a duplicate capture name fails at load" do
    dup = %{"name" => "now_screen", "launch_cmd" => "sh", "output" => "b.png"}
    data = with_capture()
    data = put_in(data, ["capture"], data["capture"] ++ [dup])

    assert {:error, reason} = Loader.from_map(data)
    assert reason =~ "duplicate"
  end

  test "a render_proof predicate loads when it names a capture" do
    rp = %{"id" => "rp", "provider" => "render_proof", "capture" => "now_screen"}
    assert {:ok, %Goal{} = goal} = Loader.from_map(with_capture(rp))
    assert Enum.any?(goal.predicates, &(&1.kind == :render_proof))
  end

  test "a render_proof predicate loads with the input = capture:<name> form" do
    rp = %{"id" => "rp", "provider" => "render_proof", "input" => "capture:now_screen"}
    assert {:ok, %Goal{}} = Loader.from_map(with_capture(rp))
  end

  test "a render_proof predicate naming no capture fails at load" do
    rp = %{"id" => "rp", "provider" => "render_proof"}
    assert {:error, reason} = Loader.from_map(with_capture(rp))
    assert reason =~ "render_proof"
    assert reason =~ "capture"
  end
end
