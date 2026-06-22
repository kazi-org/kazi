defmodule Kazi.Goal.LoaderTest do
  use ExUnit.Case, async: true
  doctest Kazi.Goal.Loader

  alias Kazi.{Budget, Goal, Predicate, Scope}
  alias Kazi.Goal.Loader

  @example_path Path.join([
                  File.cwd!(),
                  "priv",
                  "examples",
                  "deploy_target.toml"
                ])

  describe "load/1 — the checked-in example goal fixture" do
    test "parses priv/examples/deploy_target.toml into a Goal" do
      assert {:ok, %Goal{} = goal} = Loader.load(@example_path)

      assert goal.id == "deploy-target-slice0"
      assert goal.name =~ "Slice 0"
      assert goal.metadata == %{"fixture" => "fixtures/deploy-target", "slice" => "0"}

      assert %Budget{max_iterations: 10, max_tokens: 500_000, max_wall_clock_ms: nil} =
               goal.budget

      assert %Scope{workspace: "fixtures/deploy-target", paths: ["main.go"], repo: nil} =
               goal.scope
    end

    test "the CODE predicate is a test_runner over the fixture's go test" do
      assert {:ok, goal} = Loader.load(@example_path)

      # Both example predicates are ordinary (non-guard) goals to reach.
      assert goal.guards == []
      assert [tests, _live] = goal.predicates

      assert %Predicate{id: "go-tests", kind: :tests, guard?: false} = tests
      assert tests.config[:cmd] == "go test ./..."
      assert tests.description =~ "go test"
    end

    test "the LIVE predicate is an http_probe asserting /livez returns \"ok\" (exact)" do
      assert {:ok, goal} = Loader.load(@example_path)
      assert [_tests, live] = goal.predicates

      # /livez, not /healthz: Cloud Run intercepts /healthz (L-0003); and an exact
      # body match, because "ok" is a substring of the failing "not-ok" (L-0004).
      assert %Predicate{id: "livez-live", kind: :http_probe, guard?: false} = live
      assert live.config[:url] =~ "/livez"
      assert live.config[:expect_status] == 200
      assert live.config[:expect_body] == "ok"
      assert live.config[:body_match] == "exact"
    end
  end

  describe "creation mode (T2.1) — the checked-in create-feature example" do
    @create_path Path.join([File.cwd!(), "priv", "examples", "create_feature.toml"])

    test "parses priv/examples/create_feature.toml into a create-mode Goal" do
      assert {:ok, %Goal{} = goal} = Loader.load(@create_path)

      assert goal.id == "create-widgets-api"
      assert goal.name =~ "Creation mode"
      assert goal.mode == :create
      assert Goal.create?(goal)
    end

    test "the example's predicates are http_probe acceptance criteria" do
      assert {:ok, goal} = Loader.load(@create_path)

      # All ordinary predicates (no guards), all acceptance criteria over the
      # http_probe provider — the create-mode authoring pattern.
      assert goal.guards == []
      assert length(goal.predicates) == 2
      assert Enum.all?(goal.predicates, &(&1.kind == :http_probe))
      assert Enum.all?(goal.predicates, & &1.acceptance?)

      acceptance_ids = goal |> Goal.acceptance_predicates() |> Enum.map(& &1.id)
      assert acceptance_ids == ["widgets-list-200", "widgets-list-body"]

      # The acceptance config is carried verbatim to the http_probe provider: the
      # criteria are "GET /widgets returns 200 (with the expected body)" — failing
      # at t0 because the endpoint does not exist yet.
      [list, body] = goal.predicates
      assert list.config[:path] == "/widgets"
      assert list.config[:expect_status] == 200
      assert body.config[:expect_body] == "widgets"
    end
  end

  describe "creation mode (T2.1) — schema additions" do
    test "goal mode defaults to :repair when omitted" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "http_probe"}]}
      assert {:ok, %Goal{mode: :repair}} = Loader.from_map(data)
    end

    test "mode = \"create\" parses to :create" do
      data = %{
        "id" => "g",
        "mode" => "create",
        "predicate" => [%{"id" => "p", "provider" => "http_probe", "acceptance" => true}]
      }

      assert {:ok, %Goal{mode: :create} = goal} = Loader.from_map(data)
      assert Goal.create?(goal)
    end

    test "an unknown mode is a load-time validation error" do
      data = %{
        "id" => "g",
        "mode" => "destroy",
        "predicate" => [%{"id" => "p", "provider" => "http_probe"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "mode"
      assert reason =~ "destroy"
    end

    test "a non-string mode is rejected" do
      data = %{
        "id" => "g",
        "mode" => 1,
        "predicate" => [%{"id" => "p", "provider" => "http_probe"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "mode"
    end

    test "acceptance = true marks a predicate as an acceptance criterion" do
      data = %{
        "id" => "g",
        "predicate" => [%{"id" => "p", "provider" => "http_probe", "acceptance" => true}]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert [%Predicate{id: "p", acceptance?: true}] = goal.predicates
    end

    test "acceptance defaults to false and is not collected into config" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "http_probe"}]}
      assert {:ok, goal} = Loader.from_map(data)
      assert [%Predicate{acceptance?: false, config: config}] = goal.predicates
      refute Map.has_key?(config, :acceptance)
    end

    test "a non-boolean acceptance is rejected" do
      data = %{
        "id" => "g",
        "predicate" => [%{"id" => "p", "provider" => "http_probe", "acceptance" => "yes"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "acceptance"
    end

    test "a predicate may not be both a guard and an acceptance predicate" do
      data = %{
        "id" => "g",
        "predicate" => [
          %{"id" => "p", "provider" => "http_probe", "guard" => true, "acceptance" => true}
        ]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "guard"
      assert reason =~ "acceptance"
    end
  end

  describe "standing mode (T3.4d) — schema additions" do
    test "goal standing defaults to false when omitted" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]}
      assert {:ok, %Goal{standing: false} = goal} = Loader.from_map(data)
      refute Goal.standing?(goal)
    end

    test "standing = true parses to a standing goal" do
      data = %{
        "id" => "g",
        "standing" => true,
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, %Goal{standing: true} = goal} = Loader.from_map(data)
      assert Goal.standing?(goal)
    end

    test "a non-boolean standing is a load-time validation error" do
      data = %{
        "id" => "g",
        "standing" => "yes",
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "standing"
    end

    test "the checked-in standing example loads as a standing goal" do
      path = Path.join([File.cwd!(), "priv", "examples", "standing_maintenance.toml"])
      assert {:ok, %Goal{} = goal} = Loader.load(path)
      assert goal.id == "standing-maintenance-example"
      assert Goal.standing?(goal)
      assert Enum.map(goal.predicates, & &1.id) == ["tests-green", "healthz-live"]
    end
  end

  describe "prod_log provider (T1.6) — author + dispatch" do
    test "parses a goal declaring the prod_log provider into a :prod_log predicate" do
      toml = """
      id = "prod-clean"

      [[predicate]]
      id = "logs-clean"
      provider = "prod_log"
      description = "no 5xx/panics over the last 30m"
      cmd = "gcloud"
      args = ["logging", "read", "severity>=ERROR", "--freshness=30m"]
      window_minutes = 30
      max_5xx = 0
      """

      assert {:ok, goal} = Loader.from_map(Toml.decode!(toml))
      assert [%Predicate{id: "logs-clean", kind: :prod_log} = pred] = goal.predicates
      assert pred.config[:cmd] == "gcloud"
      assert pred.config[:window_minutes] == 30
      assert pred.config[:max_5xx] == 0
    end

    test "the runtime maps the :prod_log kind to the ProdLog provider module" do
      assert Kazi.Runtime.provider_modules()[:prod_log] == Kazi.Providers.ProdLog
    end
  end

  describe "browser provider (T2.2) — author + dispatch" do
    test "parses a goal declaring the browser provider into a :browser predicate" do
      toml = """
      id = "ui-acceptance"

      [[predicate]]
      id = "home-renders"
      provider = "browser"
      description = "home page shows the welcome heading"
      url = "https://app.example.test/"

      [[predicate.assertions]]
      type = "text"
      selector = "h1"
      contains = "Welcome"
      """

      assert {:ok, goal} = Loader.from_map(Toml.decode!(toml))
      assert [%Predicate{id: "home-renders", kind: :browser} = pred] = goal.predicates
      assert pred.config[:url] == "https://app.example.test/"
      assert [%{"type" => "text", "selector" => "h1"}] = pred.config[:assertions]
    end

    test "the runtime maps the :browser kind to the Browser provider module" do
      assert Kazi.Runtime.provider_modules()[:browser] == Kazi.Providers.Browser
    end
  end

  describe "from_map/1 — schema coverage" do
    test "sorts guard predicates into guards, keeps order within each bucket" do
      data = %{
        "id" => "g",
        "predicate" => [
          %{"id" => "p1", "provider" => "test_runner"},
          %{"id" => "inv", "provider" => "test_runner", "guard" => true},
          %{"id" => "p2", "provider" => "http_probe"}
        ]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert Enum.map(goal.predicates, & &1.id) == ["p1", "p2"]
      assert Enum.map(goal.guards, & &1.id) == ["inv"]
      assert hd(goal.guards).guard? == true
    end

    test "collects non-reserved predicate keys into config as atoms" do
      data = %{
        "id" => "g",
        "predicate" => [
          %{
            "id" => "p",
            "provider" => "http_probe",
            "description" => "probe",
            "url" => "http://x/healthz",
            "expect_status" => 200,
            "expect_body" => "ok"
          }
        ]
      }

      assert {:ok, goal} = Loader.from_map(data)
      [p] = goal.predicates
      assert p.description == "probe"
      assert p.config == %{url: "http://x/healthz", expect_status: 200, expect_body: "ok"}
      refute Map.has_key?(p.config, :id)
      refute Map.has_key?(p.config, :provider)
    end

    test "budget and scope are optional" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]}
      assert {:ok, goal} = Loader.from_map(data)
      assert goal.budget == %Budget{}
      assert goal.scope == %Scope{}
    end
  end

  describe "load/1 / from_map/1 — validation errors" do
    test "missing file returns a readable error" do
      assert {:error, reason} = Loader.load("/no/such/goal-file.toml")
      assert reason =~ "cannot read goal-file"
    end

    test "malformed TOML on disk is reported, not raised" do
      path =
        Path.join(System.tmp_dir!(), "kazi-malformed-#{System.unique_integer([:positive])}.toml")

      File.write!(path, "id = \nthis is not valid toml [[[")
      on_exit(fn -> File.rm(path) end)

      assert {:error, reason} = Loader.load(path)
      assert reason =~ "malformed TOML"
    end

    test "missing id is rejected" do
      assert {:error, reason} =
               Loader.from_map(%{"predicate" => [%{"id" => "p", "provider" => "test_runner"}]})

      assert reason =~ ~s(missing required key "id")
    end

    test "a goal with no predicates is rejected" do
      assert {:error, reason} = Loader.from_map(%{"id" => "g"})
      assert reason =~ "at least one [[predicate]]"
    end

    test "an unknown provider is rejected with the known set listed" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "no_such_provider"}]}
      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "unknown provider"
      assert reason =~ "test_runner"
      assert reason =~ "http_probe"
    end

    test "a predicate missing its provider is rejected" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p"}]}
      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ ~s(missing required key "provider")
    end

    test "a non-positive budget value is rejected" do
      data = %{
        "id" => "g",
        "budget" => %{"max_iterations" => 0},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "budget.max_iterations must be a positive integer"
    end

    test "a non-string scope.workspace is rejected" do
      data = %{
        "id" => "g",
        "scope" => %{"workspace" => 42},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "scope.workspace must be a string"
    end
  end
end
