defmodule Kazi.Providers.RenderProofTest do
  @moduledoc """
  ADR-0081 (#1521): the render_proof predicate gates on a CONTROLLER-produced
  capture being a plausible non-blank/non-crash frame, so a UI goal cannot
  converge on file presence.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.RenderProof

  @moduletag :tmp_dir

  defp predicate(config), do: Predicate.new(:render, :render_proof, config: config)

  defp write_artifact(tmp_dir, name, bytes) do
    path = Path.join(tmp_dir, name)
    File.write!(path, bytes)
    path
  end

  defp ok_capture(path, bytes) do
    %{
      name: "now_screen",
      ok: true,
      exit: 0,
      artifact_path: path,
      bytes: byte_size(bytes),
      sha256: "deadbeef",
      ran_at: "t",
      reason: nil
    }
  end

  test "passes on a non-blank, high-entropy artifact", %{tmp_dir: tmp_dir} do
    bytes = :crypto.strong_rand_bytes(4096)
    path = write_artifact(tmp_dir, "good.png", bytes)
    ctx = %{captures: %{"now_screen" => ok_capture(path, bytes)}}

    result = RenderProof.evaluate(predicate(%{capture: "now_screen"}), ctx)
    assert result.status == :pass
    assert result.evidence.rendered == true
  end

  test "FAILS when the capture failed (app crashed / rendered nothing)" do
    # The controller's capture produced no frame — a launch that ran but wrote
    # nothing (the crash/blank case). render_proof must be :fail (real work).
    failed = %{
      name: "now_screen",
      ok: false,
      exit: 0,
      artifact_path: nil,
      bytes: nil,
      sha256: nil,
      ran_at: "t",
      reason: :no_artifact
    }

    result =
      RenderProof.evaluate(predicate(%{capture: "now_screen"}), %{
        captures: %{"now_screen" => failed}
      })

    assert result.status == :fail
    assert result.evidence.reason == :no_artifact
  end

  test "FAILS on a blank / solid-fill artifact (below the entropy floor)", %{tmp_dir: tmp_dir} do
    # 4 KiB of a single byte value: over the size floor, but one distinct byte —
    # a blank/crash-screen fill, not a rendered UI.
    bytes = :binary.copy(<<0>>, 4096)
    path = write_artifact(tmp_dir, "blank.png", bytes)
    ctx = %{captures: %{"now_screen" => ok_capture(path, bytes)}}

    result = RenderProof.evaluate(predicate(%{capture: "now_screen"}), ctx)
    assert result.status == :fail
    assert result.evidence.reason == :below_entropy_floor
  end

  test "FAILS on a too-small artifact (below the size floor)", %{tmp_dir: tmp_dir} do
    bytes = :crypto.strong_rand_bytes(50)
    path = write_artifact(tmp_dir, "tiny.png", bytes)
    ctx = %{captures: %{"now_screen" => ok_capture(path, bytes)}}

    result = RenderProof.evaluate(predicate(%{capture: "now_screen"}), ctx)
    assert result.status == :fail
    assert result.evidence.reason == :below_size_floor
  end

  test "ERRORS (not fails) when the named capture is absent — infra, not failing work" do
    result = RenderProof.evaluate(predicate(%{capture: "missing"}), %{captures: %{}})
    assert result.status == :error
    assert result.evidence.reason == :capture_not_found
  end

  test "resolves the capture via the `input = capture:<name>` form", %{tmp_dir: tmp_dir} do
    bytes = :crypto.strong_rand_bytes(4096)
    path = write_artifact(tmp_dir, "g.png", bytes)
    ctx = %{captures: %{"now_screen" => ok_capture(path, bytes)}}

    result = RenderProof.evaluate(predicate(%{input: "capture:now_screen"}), ctx)
    assert result.status == :pass
  end

  test "custom floors override the defaults", %{tmp_dir: tmp_dir} do
    bytes = :crypto.strong_rand_bytes(100)
    path = write_artifact(tmp_dir, "small.png", bytes)
    ctx = %{captures: %{"now_screen" => ok_capture(path, bytes)}}

    result =
      RenderProof.evaluate(
        predicate(%{capture: "now_screen", min_bytes: 10, min_distinct_bytes: 4}),
        ctx
      )

    assert result.status == :pass
  end

  test "the render_proof provider result is a PredicateResult" do
    result = RenderProof.evaluate(predicate(%{capture: "x"}), %{captures: %{}})
    assert %PredicateResult{} = result
  end
end
