defmodule Kazi.Providers.CoverageTest do
  # Tier 2: real boundary. These run actual coverage-emitting commands via
  # System.cmd in a temp workspace and assert the resulting PredicateResult,
  # proving the :coverage provider gates patch coverage on a target and project
  # coverage on a no-regression ratchet (T32.8, ADR-0043).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Coverage

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_coverage_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp predicate(config), do: Predicate.new(:coverage, :coverage, config: config)

  defp evaluate(config, ws),
    do: Coverage.evaluate(predicate(config), %{workspace: ws, ratchet_store_dir: ws})

  # A metric command that prints `json` to stdout (read via `path`).
  defp metric(json, path), do: %{cmd: "sh", args: ["-c", "printf '%s' '#{json}'"], path: path}

  test "implements the PredicateProvider behaviour" do
    behaviours = Coverage.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "patch coverage vs target" do
    test "the walking skeleton (patch >= target) passes", %{workspace: ws} do
      config = %{
        patch: metric(~s({"patch":{"percent":100}}), "$.patch.percent"),
        target: 80.0
      }

      result = evaluate(config, ws)
      assert %PredicateResult{status: :pass} = result
      assert result.evidence.patch_coverage == 100
      assert result.evidence.target == 80.0
      # Envelope v2: the headline score is the patch coverage, higher_better.
      assert result.score == 100.0
      assert result.direction == :higher_better
    end

    test "a patch-coverage drop below target fails", %{workspace: ws} do
      config = %{
        patch: metric(~s({"patch":{"percent":60}}), "$.patch.percent"),
        target: 80.0
      }

      result = evaluate(config, ws)
      assert result.status == :fail
      assert result.evidence.patch_coverage == 60
      assert result.score == 60.0
    end

    test "patch exactly at target passes (>= is the bar)", %{workspace: ws} do
      config = %{
        patch: metric(~s({"patch":{"percent":80}}), "$.patch.percent"),
        target: 80.0
      }

      assert evaluate(config, ws).status == :pass
    end
  end

  describe "project no-regression" do
    test "passes when both patch and project hold", %{workspace: ws} do
      config = %{
        patch: metric(~s({"patch":{"percent":100}}), "$.patch.percent"),
        target: 80.0,
        project: metric(~s({"totals":{"percent":90}}), "$.totals.percent"),
        project_baseline: 90.0
      }

      result = evaluate(config, ws)
      assert result.status == :pass
      assert result.evidence.project_coverage == 90
      assert result.evidence.project_baseline == 90.0
    end

    test "a project-coverage regression fails even when patch passes", %{workspace: ws} do
      config = %{
        patch: metric(~s({"patch":{"percent":100}}), "$.patch.percent"),
        target: 80.0,
        project: metric(~s({"totals":{"percent":85}}), "$.totals.percent"),
        project_baseline: 90.0
      }

      result = evaluate(config, ws)
      assert result.status == :fail
      # The patch dimension still passed; the project regression is what failed.
      assert result.evidence.patch_status == :pass
      assert result.evidence.project_status == :fail
    end
  end

  describe "error handling" do
    test "a broken patch metric is :error, never a silent pass", %{workspace: ws} do
      config = %{
        patch: %{cmd: "definitely-not-a-real-binary-xyz", args: []},
        target: 80.0
      }

      result = evaluate(config, ws)
      assert result.status == :error
      assert result.evidence.dimension == :patch
    end

    test "a broken project metric is :error", %{workspace: ws} do
      config = %{
        patch: metric(~s({"patch":{"percent":100}}), "$.patch.percent"),
        target: 80.0,
        project: %{cmd: "definitely-not-a-real-binary-xyz", args: []},
        project_baseline: 90.0
      }

      result = evaluate(config, ws)
      assert result.status == :error
      assert result.evidence.dimension == :project
    end
  end

  test "an unsupported kind is an :error" do
    result = Coverage.evaluate(%Predicate{id: :x, kind: :tests, config: %{}}, %{})
    assert result.status == :error
  end
end
