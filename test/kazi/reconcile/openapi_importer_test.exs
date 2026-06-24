defmodule Kazi.Reconcile.OpenApiImporterTest do
  # T13.1: OpenAPI -> grouped http_probe acceptance predicates (ADR-0021 §1,
  # ADR-0020 groups). Hermetic — reads a committed fixture spec under
  # test/fixtures/reconcile and an in-line map; no network, no clock.
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Reconcile.OpenApiImporter

  @fixture Path.expand("../../fixtures/reconcile/petstore.openapi.json", __DIR__)

  defp fixture_json, do: File.read!(@fixture)

  describe "import_map/2 — paths/operations become grouped http_probe predicates" do
    test "one http_probe acceptance predicate per path/operation with method+path+status config" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())

      # 6 operations across 5 paths in the fixture (GET+POST /pets, GET
      # /pets/{petId}, GET /users, POST /users/{userId}/sessions, GET /healthz).
      assert length(map["predicate"]) == 6

      Enum.each(map["predicate"], fn p ->
        assert p["provider"] == "http_probe"
        assert p["acceptance"] == true
        assert p["method"] in ~w(GET POST PUT DELETE PATCH OPTIONS HEAD TRACE)
        assert is_binary(p["path"])
        assert is_integer(p["expect_status"])
        assert is_binary(p["url"])
        assert is_binary(p["group"])
      end)
    end

    test "the goal is in create mode (predicates are acceptance criteria)" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      assert map["mode"] == "create"
    end

    test "method, path, expected-status and url are set from the operation" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})

      get_pets = by_id["get_pets"]
      assert get_pets["method"] == "GET"
      assert get_pets["path"] == "/pets"
      assert get_pets["expect_status"] == 200
      # The server URL carries a trailing slash; it is trimmed before joining.
      assert get_pets["url"] == "https://api.petstore.example.com/v1/pets"

      # POST /pets declares 201 + 400 -> the smallest 2xx (201) is expected.
      post_pets = by_id["post_pets"]
      assert post_pets["method"] == "POST"
      assert post_pets["expect_status"] == 201

      # A path template is recorded verbatim (braces kept).
      get_pet = by_id["get_pets-petid"]
      assert get_pet["path"] == "/pets/{petId}"
      assert get_pet["url"] == "https://api.petstore.example.com/v1/pets/{petId}"
    end

    test "an operation with no declared 2xx response defaults to 200" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})
      # POST /users/{userId}/sessions declares only a "default" response.
      assert by_id["post_users-userid-sessions"]["expect_status"] == 200
    end

    test "the operation summary becomes the predicate description" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})
      assert by_id["get_pets"]["description"] == "List all pets"
    end
  end

  describe "import_map/2 — grouping by tag into declared [[group]] entries" do
    test "each operation's first tag becomes a declared group (id = normalized tag)" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      group_ids = map["group"] |> Enum.map(& &1["id"]) |> Enum.sort()

      # Tags: "Pets", "Identity & Access", "Identity and Access" (-> one group),
      # and an untagged operation (-> "ungrouped").
      assert group_ids == ["identity-access", "pets", "ungrouped"]
    end

    test "tag spelling variants collapse to one group (normalize_id), not two" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      ids = Enum.map(map["group"], & &1["id"])
      # "Identity & Access" and "Identity and Access" both normalize to
      # "identity-access" — the tree must not fragment (ADR-0020).
      assert Enum.count(ids, &(&1 == "identity-access")) == 1
    end

    test "an untagged operation falls into the default 'ungrouped' group" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})
      assert by_id["get_healthz"]["group"] == "ungrouped"
      assert Enum.any?(map["group"], &(&1["id"] == "ungrouped"))
    end

    test "each predicate's group references a declared group id" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      declared = MapSet.new(map["group"], & &1["id"])

      Enum.each(map["predicate"], fn p ->
        assert MapSet.member?(declared, p["group"]),
               "predicate #{p["id"]} references undeclared group #{inspect(p["group"])}"
      end)
    end
  end

  describe "round-trips through Kazi.Goal.Loader.from_map/1" do
    test "the emitted map loads into a create-mode goal with grouped acceptance predicates" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      assert {:ok, %Goal{} = goal} = Loader.from_map(map)

      assert goal.mode == :create
      assert length(goal.predicates) == 6
      assert Enum.all?(goal.predicates, &(&1.kind == :http_probe))
      assert Enum.all?(goal.predicates, & &1.acceptance?)

      # Groups round-trip with normalized ids.
      group_ids = goal.groups |> Enum.map(& &1.id) |> Enum.sort()
      assert group_ids == ["identity-access", "pets", "ungrouped"]

      # The group reference lands on Predicate.group (a declared id the loader
      # validates, T12.2); method/path/expect_status/url fall through to config.
      acceptance = Kazi.Goal.acceptance_predicates(goal)
      assert length(acceptance) == 6

      probe = Enum.find(acceptance, &(&1.id == "get_pets"))
      assert probe.group == "pets"
      assert probe.config[:method] == "GET"
      assert probe.config[:path] == "/pets"
      assert probe.config[:expect_status] == 200
      assert probe.config[:url] == "https://api.petstore.example.com/v1/pets"
    end

    test "import_goal/2 is the loader convenience wrapper" do
      assert {:ok, %Goal{mode: :create}} = OpenApiImporter.import_goal(fixture_json())
    end
  end

  describe "determinism and re-import (upsert)" do
    test "the same spec yields a byte-identical goal map" do
      {:ok, a} = OpenApiImporter.import_map(fixture_json())
      {:ok, b} = OpenApiImporter.import_map(fixture_json())
      assert a == b
    end

    test "operation key order in the document does not change the output" do
      doc = %{
        "info" => %{"title" => "Reorder"},
        "paths" => %{
          "/b" => %{
            "post" => %{"tags" => ["Z"], "responses" => %{"200" => %{}}},
            "get" => %{"tags" => ["A"], "responses" => %{"200" => %{}}}
          },
          "/a" => %{"get" => %{"tags" => ["A"], "responses" => %{"200" => %{}}}}
        }
      }

      reordered = %{
        "info" => %{"title" => "Reorder"},
        "paths" => %{
          "/a" => %{"get" => %{"tags" => ["A"], "responses" => %{"200" => %{}}}},
          "/b" => %{
            "get" => %{"tags" => ["A"], "responses" => %{"200" => %{}}},
            "post" => %{"tags" => ["Z"], "responses" => %{"200" => %{}}}
          }
        }
      }

      assert {:ok, same} = OpenApiImporter.import_map(doc)
      assert {:ok, same} == OpenApiImporter.import_map(reordered)

      # Stable order: sorted by path, then fixed method order (get before post).
      assert Enum.map(same["predicate"], & &1["id"]) == ["get_a", "get_b", "post_b"]
    end

    test "re-import produces stable ids and no duplicates (upsert)" do
      {:ok, a} = OpenApiImporter.import_map(fixture_json())
      {:ok, b} = OpenApiImporter.import_map(fixture_json())

      ids_a = Enum.map(a["predicate"], & &1["id"])
      ids_b = Enum.map(b["predicate"], & &1["id"])

      assert ids_a == ids_b

      assert ids_a == Enum.uniq(ids_a),
             "predicate ids must be unique (no duplicates on re-import)"
    end
  end

  describe "options and inputs" do
    test "accepts an already-decoded map and a JSON string identically" do
      decoded = Jason.decode!(fixture_json())
      assert OpenApiImporter.import_map(decoded) == OpenApiImporter.import_map(fixture_json())
    end

    test ":id and :name override the derived defaults" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json(), id: "petstore", name: "My Pets")
      assert map["id"] == "petstore"
      assert map["name"] == "My Pets"
    end

    test "the goal name defaults to info.title" do
      {:ok, map} = OpenApiImporter.import_map(fixture_json())
      assert map["name"] == "Petstore API"
    end

    test ":base_url overrides the spec's server url" do
      {:ok, map} =
        OpenApiImporter.import_map(fixture_json(), base_url: "https://staging.example.com")

      by_id = Map.new(map["predicate"], &{&1["id"], &1})
      assert by_id["get_pets"]["url"] == "https://staging.example.com/pets"
    end

    test "a document missing paths is a clear tagged error, not a crash" do
      assert {:error, reason} = OpenApiImporter.import_map(%{"info" => %{"title" => "x"}})
      assert reason =~ "paths"
    end

    test "malformed JSON is a human-readable error" do
      assert {:error, reason} = OpenApiImporter.import_map("{not json")
      assert reason =~ "malformed OpenAPI JSON"
    end
  end
end
