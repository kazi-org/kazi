defmodule Kazi.Reconcile.CoverageTest do
  # Hermetic: scans the same static fixture project as the surface scanner and
  # checks ownership against hand-written intended predicate sets. No network,
  # no clock.
  use ExUnit.Case, async: true

  alias Kazi.Predicate
  alias Kazi.Reconcile.{Coverage, SurfaceElement, SurfaceScanner}

  doctest Coverage

  @fixture Path.expand("../../../test/fixtures/surface", __DIR__)

  defp el(kind, id, path, line \\ 1),
    do: SurfaceElement.new(kind, id, path, line)

  describe "an un-predicated surface element fails and is named" do
    test "a single dead def is flagged and named, the rest reported owned" do
      surface = [
        el(:exported_function, "Surface.Calc.add/2", "lib/calc.ex", 5),
        el(:exported_function, "Surface.Calc.zero/0", "lib/calc.ex", 7)
      ]

      # An intended set that names only `add/2` leaves `zero/0` unowned.
      predicates = [
        Predicate.new(:add, :tests, description: "covers Surface.Calc.add/2")
      ]

      result = Coverage.check(surface, predicates)

      assert result.status == :fail
      assert Coverage.Result.unowned_identifiers(result) == ["Surface.Calc.zero/0"]
      assert ["Surface.Calc.add/2"] == Enum.map(result.owned, & &1.identifier)
    end

    test "names ALL unowned elements when the intended set is empty" do
      surface = SurfaceScanner.scan(@fixture)
      refute surface == []

      result = Coverage.check(surface, [])

      assert result.status == :fail
      # Every scanned element is unowned (no allow-list, no predicates).
      assert MapSet.new(Coverage.Result.unowned_identifiers(result)) ==
               MapSet.new(Enum.map(surface, & &1.identifier))

      assert result.owned == []
      assert result.allowed == []
    end
  end

  describe "an allow-listed element passes" do
    test "an explicit identifier on the allow-list is covered, not unowned" do
      surface = [el(:exported_function, "Kazi.Internal.Debug.dump/1", "lib/debug.ex", 3)]

      result = Coverage.check(surface, [], allow_list: ["Kazi.Internal.Debug.dump/1"])

      assert result.status == :pass
      assert Enum.map(result.allowed, & &1.identifier) == ["Kazi.Internal.Debug.dump/1"]
      assert result.unowned == []
    end

    test "a `prefix*` wildcard allows a whole namespace" do
      surface = [
        el(:exported_function, "Kazi.Internal.a/0", "lib/a.ex", 1),
        el(:exported_function, "Kazi.Internal.b/1", "lib/b.ex", 1),
        el(:exported_function, "Public.thing/0", "lib/p.ex", 1)
      ]

      result = Coverage.check(surface, [], allow_list: ["Kazi.Internal.*"])

      assert result.status == :fail

      assert Enum.map(result.allowed, & &1.identifier) == [
               "Kazi.Internal.a/0",
               "Kazi.Internal.b/1"
             ]

      # The public symbol is not allow-listed, so it remains unowned.
      assert Coverage.Result.unowned_identifiers(result) == ["Public.thing/0"]
    end
  end

  describe "a fully-owned surface passes" do
    test "every fixture element is owned by some intended predicate" do
      surface = SurfaceScanner.scan(@fixture)

      # One predicate per scanned element, each naming the element in its
      # description — exercises the generic id/description ownership path across
      # exported_function and mix_task kinds.
      predicates =
        surface
        |> Enum.with_index()
        |> Enum.map(fn {e, i} ->
          Predicate.new(:"p#{i}", :tests, description: "owns #{e.identifier}")
        end)

      result = Coverage.check(surface, predicates)

      assert result.status == :pass
      assert result.unowned == []

      assert MapSet.new(Enum.map(result.owned, & &1.identifier)) ==
               MapSet.new(Enum.map(surface, & &1.identifier))
    end

    test "an http_probe owns a matching :http_route by VERB /path and by bare path" do
      surface = [
        el(:http_route, "GET /healthz", "lib/router.ex", 10),
        el(:http_route, "/widgets", "lib/router.ex", 12)
      ]

      predicates = [
        Predicate.new(:live, :http_probe,
          config: %{url: "https://example.test/healthz?ts=1", method: :get}
        ),
        Predicate.new(:widgets, :http_probe, config: %{url: "https://example.test/widgets"})
      ]

      result = Coverage.check(surface, predicates)

      assert result.status == :pass
      assert result.unowned == []
    end

    test "a tests predicate owns a Mix task named in its command args" do
      surface = [el(:mix_task, "mix surface.greet", "lib/mix/tasks/greet.ex")]

      predicates = [
        Predicate.new(:greet, :tests, config: %{cmd: "mix", args: ["surface.greet"]})
      ]

      result = Coverage.check(surface, predicates)
      assert result.status == :pass
    end
  end

  describe "graceful handling of degenerate inputs" do
    test "an empty surface passes vacuously regardless of the intended set" do
      assert %Coverage.Result{status: :pass, owned: [], allowed: [], unowned: []} =
               Coverage.check([], [])

      assert Coverage.check([], [Predicate.new(:p, :tests)]).status == :pass
    end

    test "predicates with nil/empty config do not crash and own nothing by config" do
      surface = [el(:exported_function, "A.b/0", "lib/a.ex", 1)]
      predicates = [Predicate.new(:p, :http_probe, config: %{})]

      result = Coverage.check(surface, predicates)

      assert result.status == :fail
      assert Coverage.Result.unowned_identifiers(result) == ["A.b/0"]
    end

    test "owned / allowed / unowned partition the de-duplicated surface" do
      dup = el(:exported_function, "A.b/0", "lib/a.ex", 1)

      surface = [
        dup,
        dup,
        el(:exported_function, "Debug.dump/0", "lib/d.ex", 1),
        el(:exported_function, "Owned.thing/0", "lib/o.ex", 1)
      ]

      predicates = [Predicate.new(:p, :tests, description: "covers Owned.thing/0")]
      result = Coverage.check(surface, predicates, allow_list: ["Debug.*"])

      ids = fn list -> list |> Enum.map(& &1.identifier) |> Enum.sort() end
      all = ids.(result.owned ++ result.allowed ++ result.unowned)

      # De-duplicated to three distinct identifiers, each in exactly one bucket.
      assert all == ["A.b/0", "Debug.dump/0", "Owned.thing/0"]
      assert ids.(result.owned) == ["Owned.thing/0"]
      assert ids.(result.allowed) == ["Debug.dump/0"]
      assert ids.(result.unowned) == ["A.b/0"]
    end
  end
end
