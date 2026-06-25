defmodule Kazi.RatchetTest do
  @moduledoc """
  The build-once baseline-comparison machinery (T32.3, ADR-0041 decision 4): pure
  compare + the persisted store + the three baseline sources (literal, stored,
  git ref), exercised against real commands and a real git repo.
  """
  use ExUnit.Case, async: true

  alias Kazi.Ratchet
  alias Kazi.Ratchet.Store

  doctest Kazi.Ratchet

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_ratchet_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # A metric that prints a fixed number to stdout.
  defp const(n), do: %{cmd: "sh", args: ["-c", "printf '%s' '#{n}'"]}

  # =============================================================================
  # Pure compare
  # =============================================================================

  describe "pure verdict/regression" do
    test "higher_better: an improvement passes, a drop beyond budget fails" do
      assert Ratchet.verdict(85.0, 80.0, 0.0, :higher_better) == :pass
      assert Ratchet.verdict(80.0, 80.0, 0.0, :higher_better) == :pass
      assert Ratchet.verdict(79.0, 80.0, 0.0, :higher_better) == :fail
      # within an allowed regression of 2
      assert Ratchet.verdict(78.5, 80.0, 2.0, :higher_better) == :pass
      assert Ratchet.verdict(77.0, 80.0, 2.0, :higher_better) == :fail
    end

    test "lower_better: shrinking passes, growth beyond budget fails" do
      assert Ratchet.verdict(90.0, 100.0, 0.0, :lower_better) == :pass
      assert Ratchet.verdict(110.0, 100.0, 0.0, :lower_better) == :fail
      assert Ratchet.verdict(110.0, 100.0, 16.0, :lower_better) == :pass
    end
  end

  # =============================================================================
  # Store
  # =============================================================================

  describe "Store" do
    test "read is :none until a value is written, then round-trips", %{workspace: ws} do
      assert Store.read(ws, "cov") == :none
      assert Store.write(ws, "cov", 81.0) == :ok
      assert Store.read(ws, "cov") == {:ok, 81.0}
    end

    test "writing one id preserves the others", %{workspace: ws} do
      :ok = Store.write(ws, "cov", 80.0)
      :ok = Store.write(ws, "size", 1024.0)
      assert Store.read(ws, "cov") == {:ok, 80.0}
      assert Store.read(ws, "size") == {:ok, 1024.0}
    end
  end

  # =============================================================================
  # evaluate/2 — literal baseline
  # =============================================================================

  describe "literal baseline" do
    test "coverage (higher_better) passes when the signal beats the threshold", %{workspace: ws} do
      config = %{
        id: "cov",
        metric: const("85"),
        baseline: 80.0,
        direction: :higher_better,
        allowed_regression: 0.0
      }

      assert %Ratchet.Result{
               status: :pass,
               signal: 85.0,
               baseline: 80.0,
               baseline_source: :literal
             } =
               Ratchet.evaluate(config, %{workspace: ws})
    end

    test "coverage fails on a regression beyond the allowed amount", %{workspace: ws} do
      config = %{
        id: "cov",
        metric: const("78"),
        baseline: 80.0,
        direction: :higher_better,
        allowed_regression: 1.0
      }

      assert %Ratchet.Result{status: :fail, regression: 2.0} =
               Ratchet.evaluate(config, %{workspace: ws})
    end

    test "size (lower_better) the same mode services a size example", %{workspace: ws} do
      pass = %{id: "size", metric: const("900"), baseline: 1000.0, direction: :lower_better}

      assert %Ratchet.Result{status: :pass, signal: 900.0} =
               Ratchet.evaluate(pass, %{workspace: ws})

      fail = %{id: "size", metric: const("1100"), baseline: 1000.0, direction: :lower_better}

      assert %Ratchet.Result{status: :fail, regression: 100.0} =
               Ratchet.evaluate(fail, %{workspace: ws})
    end

    test "a literal baseline is never persisted", %{workspace: ws} do
      config = %{id: "cov", metric: const("85"), baseline: 80.0, direction: :higher_better}
      Ratchet.evaluate(config, %{workspace: ws})
      assert Store.read(Path.join(ws, ".kazi"), "cov") == :none
    end
  end

  # =============================================================================
  # evaluate/2 — stored baseline (seed -> tighten -> regression)
  # =============================================================================

  describe "stored baseline" do
    test "the first run seeds the baseline, passes, and stores it", %{workspace: ws} do
      config = %{id: "cov", metric: const("80"), baseline: "stored", direction: :higher_better}

      assert %Ratchet.Result{status: :pass, baseline_source: :seed, stored?: true} =
               Ratchet.evaluate(config, %{workspace: ws})

      assert Store.read(Path.join(ws, ".kazi"), "cov") == {:ok, 80.0}
    end

    test "an improving signal passes and TIGHTENS the stored baseline", %{workspace: ws} do
      seed = %{id: "cov", metric: const("80"), baseline: "stored", direction: :higher_better}
      Ratchet.evaluate(seed, %{workspace: ws})

      improved = %{seed | metric: const("88")}

      assert %Ratchet.Result{
               status: :pass,
               baseline: 80.0,
               baseline_source: :stored,
               stored?: true
             } =
               Ratchet.evaluate(improved, %{workspace: ws})

      # the bar ratcheted up to 88, not back to 80
      assert Store.read(Path.join(ws, ".kazi"), "cov") == {:ok, 88.0}
    end

    test "a regression fails and leaves the stored baseline untouched", %{workspace: ws} do
      seed = %{id: "cov", metric: const("88"), baseline: "stored", direction: :higher_better}
      Ratchet.evaluate(seed, %{workspace: ws})

      regressed = %{seed | metric: const("80")}

      assert %Ratchet.Result{status: :fail, baseline: 88.0, regression: 8.0, stored?: false} =
               Ratchet.evaluate(regressed, %{workspace: ws})

      # the bar held at 88 so the agent must climb back
      assert Store.read(Path.join(ws, ".kazi"), "cov") == {:ok, 88.0}
    end

    test "the store dir is overridable for clean-tree isolation (T32.4 seam)", %{workspace: ws} do
      store = Path.join(ws, "clean-tree")
      config = %{id: "cov", metric: const("80"), baseline: "stored", direction: :higher_better}

      Ratchet.evaluate(config, %{workspace: ws, ratchet_store_dir: store})

      assert Store.read(store, "cov") == {:ok, 80.0}
      assert Store.read(Path.join(ws, ".kazi"), "cov") == :none
    end
  end

  # =============================================================================
  # evaluate/2 — git-ref baseline (recomputed against another commit)
  # =============================================================================

  describe "git-ref baseline" do
    setup %{workspace: ws} do
      # A real two-commit repo: a metric script that prints the byte size of
      # artifact.bin, with the artifact growing between commits.
      sh!(ws, "git init -q")
      sh!(ws, "git config user.email t@example.com")
      sh!(ws, "git config user.name Test")
      File.write!(Path.join(ws, "size.sh"), "wc -c < artifact.bin\n")
      File.write!(Path.join(ws, "artifact.bin"), String.duplicate("a", 100))
      sh!(ws, "git add -A && git commit -q -m c1")
      File.write!(Path.join(ws, "artifact.bin"), String.duplicate("a", 130))
      sh!(ws, "git add -A && git commit -q -m c2")
      :ok
    end

    test "recomputes the metric at the ref and fails on growth beyond budget", %{workspace: ws} do
      config = %{
        id: "size",
        metric: %{cmd: "sh", args: ["size.sh"]},
        baseline: "HEAD~1",
        direction: :lower_better,
        allowed_regression: 0.0
      }

      assert %Ratchet.Result{
               status: :fail,
               baseline_source: :git_ref,
               baseline: 100.0,
               signal: 130.0,
               regression: 30.0
             } = Ratchet.evaluate(config, %{workspace: ws})
    end

    test "passes when growth is within the allowed regression", %{workspace: ws} do
      config = %{
        id: "size",
        metric: %{cmd: "sh", args: ["size.sh"]},
        baseline: "HEAD~1",
        direction: :lower_better,
        allowed_regression: 64.0
      }

      assert %Ratchet.Result{status: :pass, baseline_source: :git_ref} =
               Ratchet.evaluate(config, %{workspace: ws})
    end

    test "an unresolvable ref is an :error, never a pass", %{workspace: ws} do
      config = %{
        id: "size",
        metric: %{cmd: "sh", args: ["size.sh"]},
        baseline: "no-such-ref",
        direction: :lower_better
      }

      assert %Ratchet.Result{status: :error, reason: {:baseline_ref_unresolved, "no-such-ref", _}} =
               Ratchet.evaluate(config, %{workspace: ws})
    end
  end

  # =============================================================================
  # evaluate/2 — error paths
  # =============================================================================

  describe "errors" do
    test "a broken metric is an :error, never a pass", %{workspace: ws} do
      config = %{
        id: "cov",
        metric: %{cmd: "definitely-not-a-real-binary-xyz"},
        baseline: 80.0,
        direction: :higher_better
      }

      assert %Ratchet.Result{status: :error, reason: {:metric_unrunnable, _}} =
               Ratchet.evaluate(config, %{workspace: ws})
    end

    test "a missing baseline is an :error", %{workspace: ws} do
      config = %{id: "cov", metric: const("80"), direction: :higher_better}

      assert %Ratchet.Result{status: :error, reason: :missing_baseline} =
               Ratchet.evaluate(config, %{workspace: ws})
    end

    test "an invalid direction is an :error" do
      config = %{id: "cov", metric: const("80"), baseline: 80.0, direction: :sideways}

      assert %Ratchet.Result{status: :error, reason: {:invalid_direction, :sideways}} =
               Ratchet.evaluate(config, %{workspace: File.cwd!()})
    end
  end

  defp sh!(dir, command) do
    {_out, 0} = System.cmd("sh", ["-c", command], cd: dir, stderr_to_stdout: true)
  end
end
