defmodule Kazi.Reconcile.SurfaceScannerTest do
  # Hermetic: scans a static on-disk fixture and (for edge cases) a temp tree.
  # No network, no clock — pure over the filesystem.
  use ExUnit.Case, async: true

  alias Kazi.Reconcile.{SurfaceElement, SurfaceScanner}

  doctest SurfaceScanner

  @fixture Path.expand("../../fixtures/surface", __DIR__)

  defp identifiers(elements, kind) do
    elements
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.identifier)
  end

  describe "scan/2 over the fixture project" do
    test "inventories public defs as Module.fun/arity, omitting private defs" do
      funs = SurfaceScanner.scan(@fixture) |> identifiers(:exported_function)

      assert "Surface.Calc.add/2" in funs
      assert "Surface.Calc.zero/0" in funs
      assert "Surface.Calc.double/1" in funs

      # defp internal/1 and defp hidden/1 are NOT surface.
      refute "Surface.Calc.internal/1" in funs
      refute "Surface.Outer.Inner.hidden/1" in funs
    end

    test "composes nested module names and unwraps guards" do
      funs = SurfaceScanner.scan(@fixture) |> identifiers(:exported_function)

      # `def top(x) when is_integer(x)` is arity 1, attributed to the outer module.
      assert "Surface.Outer.top/1" in funs
      # Nested module composes its parent's name.
      assert "Surface.Outer.Inner.deep/3" in funs
    end

    test "discovers Mix tasks as `mix <task>` from the Mix.Tasks.* convention" do
      tasks = SurfaceScanner.scan(@fixture) |> identifiers(:mix_task)
      assert "mix surface.greet" in tasks
    end

    test "every element carries a workspace-relative path and (for defs) a line" do
      elements = SurfaceScanner.scan(@fixture)

      add = Enum.find(elements, &(&1.identifier == "Surface.Calc.add/2"))
      assert %SurfaceElement{kind: :exported_function, path: "lib/calc.ex"} = add
      assert is_integer(add.line) and add.line > 0
      # Paths are workspace-relative, never absolute.
      assert Enum.all?(elements, &(not String.starts_with?(&1.path, "/")))
    end

    test "is deterministic: repeated scans are byte-identical and sorted" do
      first = SurfaceScanner.scan(@fixture)
      second = SurfaceScanner.scan(@fixture)

      assert first == second
      assert first == Enum.sort_by(first, &SurfaceElement.sort_key/1)
    end
  end

  describe "scan/2 Mix.Project boilerplate exclusion" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "kazi_surface_mix_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "a boilerplate-only mix.exs yields zero surface elements", %{root: root} do
      File.write!(Path.join(root, "mix.exs"), """
      defmodule Demo.Mixfile do
        use Mix.Project

        def project do
          [app: :demo, version: "0.1.0", deps: deps()]
        end

        def application do
          [extra_applications: [:logger]]
        end

        def cli do
          [preferred_envs: [docs: :docs]]
        end

        defp deps, do: []
      end
      """)

      assert SurfaceScanner.scan(root) == []
    end

    test "a custom public helper in mix.exs still surfaces", %{root: root} do
      File.write!(Path.join(root, "mix.exs"), """
      defmodule Demo.Mixfile do
        use Mix.Project

        def project do
          [app: :demo, version: version(), deps: deps()]
        end

        def application, do: []

        def version, do: "1.2.3"

        defp deps, do: []
      end
      """)

      funs = SurfaceScanner.scan(root) |> identifiers(:exported_function)
      assert "Demo.Mixfile.version/0" in funs
      refute "Demo.Mixfile.project/0" in funs
      refute "Demo.Mixfile.application/0" in funs
    end

    test "callbacks named project/0 in a non-Mix.Project module are still surface", %{root: root} do
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(Path.join(root, "lib/plain.ex"), """
      defmodule Plain do
        def project, do: :ok
        def application, do: :ok
      end
      """)

      funs = SurfaceScanner.scan(root) |> identifiers(:exported_function)
      assert "Plain.project/0" in funs
      assert "Plain.application/0" in funs
    end
  end

  describe "scan/2 robustness" do
    setup do
      root = Path.join(System.tmp_dir!(), "kazi_surface_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "deps/ignored"))
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "skips dependency directories", %{root: root} do
      File.write!(Path.join(root, "lib/ok.ex"), "defmodule Ok do\n  def go, do: :ok\nend\n")

      File.write!(
        Path.join(root, "deps/ignored/dep.ex"),
        "defmodule Dep do\n  def leaked, do: :ok\nend\n"
      )

      funs = SurfaceScanner.scan(root) |> identifiers(:exported_function)
      assert "Ok.go/0" in funs
      refute "Dep.leaked/0" in funs
    end

    test "an unparseable file is skipped, not fatal", %{root: root} do
      File.write!(Path.join(root, "lib/good.ex"), "defmodule Good do\n  def fine, do: :ok\nend\n")
      File.write!(Path.join(root, "lib/broken.ex"), "defmodule Broken do\n  def oops( unclosed\n")

      funs = SurfaceScanner.scan(root) |> identifiers(:exported_function)
      assert "Good.fine/0" in funs
    end

    test "an empty tree yields an empty inventory", %{root: root} do
      assert SurfaceScanner.scan(root) == []
    end
  end
end
