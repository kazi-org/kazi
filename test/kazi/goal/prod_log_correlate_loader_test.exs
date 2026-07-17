defmodule Kazi.Goal.ProdLogCorrelateLoaderTest do
  @moduledoc """
  T41.5 (ADR-0051 decision 4): the loader admits a prod_log `correlate` table as a
  KNOWN config key and validates its shape, so a mis-declared trust-check fails at
  LOAD rather than as a silent no-op the author reads as "correlation isn't working"
  (the same silent-config-error shape the download-assertion loader guard prevents).

  Admitting it as a known key also matters for the RELEASE binary: `correlate` is a
  compile-time atom literal in `Kazi.Providers.ProdLog`, so `ensure_provider_loaded`
  interns it before the loader's `String.to_existing_atom/1` check — the same
  mechanism `:cmd`/`:max_5xx` rely on. A goal-file that names `correlate` must load,
  not be rejected as an unknown key (the atom-interning landmine, devlog 2026-07-15).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(correlate) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [
        %{
          "id" => "p",
          "provider" => "prod_log",
          "cmd" => "echo",
          "correlate" => correlate
        }
      ]
    })
  end

  test "correlate is a KNOWN config key — a prod_log goal that names it loads" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :prod_log, config: config}]}} =
             load(%{"route" => "/checkout", "window" => 60})

    # Admitted (not rejected as unknown) and reaches the provider verbatim.
    assert config[:correlate] == %{"route" => "/checkout", "window" => 60}
  end

  test "a prod_log goal with NO correlate still loads (opt-in, unchanged)" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :prod_log}]}} =
             Loader.from_map(%{
               "id" => "g",
               "predicate" => [%{"id" => "p", "provider" => "prod_log", "cmd" => "echo"}]
             })
  end

  test "window is optional" do
    assert {:ok, _} = load(%{"route" => "/checkout"})
  end

  test "a non-table correlate is a load error (a bare string is the common typo)" do
    assert {:error, msg} =
             Loader.from_map(%{
               "id" => "g",
               "predicate" => [
                 %{
                   "id" => "p",
                   "provider" => "prod_log",
                   "cmd" => "echo",
                   "correlate" => "/checkout"
                 }
               ]
             })

    assert msg =~ "correlate"
    assert msg =~ "inline table"
  end

  test "a missing/empty route is a load error" do
    assert {:error, msg} = load(%{"window" => 60})
    assert msg =~ "route"

    assert {:error, msg2} = load(%{"route" => ""})
    assert msg2 =~ "route"
  end

  test "a non-numeric window is a load error" do
    assert {:error, msg} = load(%{"route" => "/checkout", "window" => "sixty"})
    assert msg =~ "window"
    assert msg =~ "number"
  end
end
