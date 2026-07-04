defmodule Kazi.Ratchet.StoreAtomicityTest do
  @moduledoc """
  M2 (deep-review-001): `Store.write/3` is atomic (temp file + rename, never a
  partial file visible at the store path) and `Store.read/2` distinguishes a
  corrupt store from a missing one, so a truncated `ratchets.json` surfaces as a
  predicate `:error` instead of silently reseeding the ratchet at the current
  (possibly regressed) signal.
  """
  use ExUnit.Case, async: true

  alias Kazi.Ratchet
  alias Kazi.Ratchet.Store

  setup do
    dir =
      Path.join(System.tmp_dir!(), "kazi_ratchet_atomic_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  describe "write/3 atomicity" do
    test "writes leave no stray temp file behind", %{workspace: ws} do
      :ok = Store.write(ws, "cov", 81.0)

      assert File.ls!(ws) == ["ratchets.json"]
      assert Store.read(ws, "cov") == {:ok, 81.0}
    end

    test "the store file is never observed truncated/partial (rename is atomic)", %{
      workspace: ws
    } do
      :ok = Store.write(ws, "cov", 1.0)

      for n <- 2..20 do
        :ok = Store.write(ws, "cov", n * 1.0)
        contents = File.read!(Store.path(ws))
        assert {:ok, _} = Jason.decode(contents)
      end

      assert Store.read(ws, "cov") == {:ok, 20.0}
    end
  end

  describe "read/2 corrupt-vs-missing" do
    test "a missing store is :none", %{workspace: ws} do
      assert Store.read(ws, "cov") == :none
    end

    test "a present-but-corrupt store is {:error, :corrupt}, never :none", %{workspace: ws} do
      File.write!(Store.path(ws), "{not valid json")

      assert Store.read(ws, "cov") == {:error, :corrupt}
    end

    test "a present store with non-map JSON is {:error, :corrupt}", %{workspace: ws} do
      File.write!(Store.path(ws), "[1, 2, 3]")

      assert Store.read(ws, "cov") == {:error, :corrupt}
    end
  end

  describe "Ratchet.evaluate/2 on a corrupt store" do
    defp const(n), do: %{cmd: "sh", args: ["-c", "printf '%s' '#{n}'"]}

    test "a corrupt store surfaces as :error, not a silent reseed at the current value", %{
      workspace: ws
    } do
      File.write!(Store.path(ws), "not json at all")

      # `:store_dir` pins the store to `ws` (where the corrupt file was written);
      # without it `evaluate/2` defaults to `<workspace>/.kazi`, which is empty —
      # a missing store, not a corrupt one — and the ratchet would just seed.
      config = %{
        id: "cov",
        metric: const(50.0),
        baseline: "stored",
        direction: :higher_better,
        store_dir: ws
      }

      result = Ratchet.evaluate(config, %{workspace: ws})

      assert result.status == :error
      assert result.reason == {:ratchet_store_corrupt, "cov"}

      # Crucially, the corrupt store must NOT have been overwritten/reseeded.
      assert File.read!(Store.path(ws)) == "not json at all"
    end
  end
end
