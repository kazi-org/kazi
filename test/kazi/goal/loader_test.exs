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

  describe "harness selection (T8.6, ADR-0016) — [harness] table" do
    test "goal harness stays nil when no [harness] table is present (back-compat)" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]}
      assert {:ok, %Goal{harness: nil}} = Loader.from_map(data)
    end

    test "an absent [harness] loads identically to a goal authored before T8.6" do
      # A goal-file with no [harness] must load EXACTLY as it did before this
      # field existed: the harness field is nil and nothing else is perturbed.
      data = %{
        "id" => "legacy",
        "name" => "Legacy goal",
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert goal.harness == nil
      assert goal.id == "legacy"
      assert goal.name == "Legacy goal"
      assert goal.mode == :repair
      assert goal.standing == false
      assert [%Predicate{id: "p", kind: :tests}] = goal.predicates
    end

    test "a [harness] table with id + model parses into the harness map" do
      data = %{
        "id" => "g",
        "harness" => %{"id" => "opencode", "model" => "dgx/qwen3.6"},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, %Goal{harness: harness}} = Loader.from_map(data)
      assert harness == %{id: :opencode, model: "dgx/qwen3.6", command: nil}
    end

    test "a [harness] id-only table parses with nil model/command" do
      data = %{
        "id" => "g",
        "harness" => %{"id" => "claude"},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, %Goal{harness: %{id: :claude, model: nil, command: nil}}} =
               Loader.from_map(data)
    end

    test "the loaded harness id threads into Kazi.Harness.resolve/1 as :goal_harness" do
      data = %{
        "id" => "g",
        "harness" => %{"id" => "opencode"},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, %Goal{harness: %{id: :opencode}}} = Loader.from_map(data)

      # The loaded id selects the matching profile (resolution wiring into
      # Runtime is T8.7; here we just prove the field feeds resolution).
      assert {:ok, {_adapter, adapter_opts}} =
               Kazi.Harness.resolve(goal_harness: :opencode)

      assert adapter_opts[:profile].id == :opencode
    end

    test "a non-table [harness] is a load-time validation error" do
      data = %{
        "id" => "g",
        "harness" => "opencode",
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "[harness] must be a table"
    end

    test "a [harness] table missing id is a validation error" do
      data = %{
        "id" => "g",
        "harness" => %{"model" => "dgx/qwen3.6"},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "missing required key \"id\""
    end

    test "a [harness] id that is not a string is a validation error" do
      data = %{
        "id" => "g",
        "harness" => %{"id" => 42},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "harness.id must be a string"
    end

    test "an unknown [harness] id fails loudly (no atom leak)" do
      data = %{
        "id" => "g",
        "harness" => %{"id" => "nope-not-a-harness"},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "unknown harness"
    end

    test "a non-string harness.model is a validation error" do
      data = %{
        "id" => "g",
        "harness" => %{"id" => "opencode", "model" => 7},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "harness.model must be a string"
    end

    test "the full [harness] table parses from TOML text" do
      toml = """
      id = "g"

      [harness]
      id = "opencode"
      model = "dgx/qwen3.6"
      command = "/usr/local/bin/opencode"

      [[predicate]]
      id = "p"
      provider = "test_runner"
      """

      assert {:ok, %Goal{harness: harness}} = Loader.from_map(Toml.decode!(toml))

      assert harness == %{
               id: :opencode,
               model: "dgx/qwen3.6",
               command: "/usr/local/bin/opencode"
             }
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

  describe "group taxonomy (T12.1, ADR-0020) — [[group]] array" do
    alias Kazi.Goal.Group

    test "a goal with no [[group]] loads an empty group set (back-compat)" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]}
      assert {:ok, %Goal{groups: []}} = Loader.from_map(data)
    end

    test "an absent [[group]] loads identically to a goal authored before T12.1" do
      # A goal-file with no [[group]] must load EXACTLY as it did before this
      # field existed: groups is [] and nothing else is perturbed.
      toml = """
      id = "g"
      name = "n"

      [[predicate]]
      id = "p"
      provider = "test_runner"
      """

      assert {:ok, goal} = Loader.from_map(Toml.decode!(toml))
      assert goal.groups == []
      assert goal.id == "g"
      assert goal.name == "n"
      assert [%Predicate{id: "p"}] = goal.predicates
    end

    test "parses a [[group]] array into a validated group set on the goal" do
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "identity-access", "name" => "Identity & Access"},
          %{"id" => "billing", "name" => "Billing", "budget" => 5}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, %Goal{groups: groups}} = Loader.from_map(data)

      assert [
               %Group{id: "identity-access", name: "Identity & Access", parent: nil, budget: nil},
               %Group{id: "billing", name: "Billing", parent: nil, budget: 5}
             ] = groups
    end

    test "a group id normalizes case / whitespace / & into a canonical slug" do
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "Identity & Access", "name" => "Identity & Access"},
          %{"id" => "  Sign  Up  ", "name" => "Sign Up"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert Enum.map(goal.groups, & &1.id) == ["identity-access", "sign-up"]
      # The display name is kept verbatim; only the id is normalized.
      assert Enum.map(goal.groups, & &1.name) == ["Identity & Access", "Sign Up"]
    end

    test "a parent reference is parsed and stored (normalized)" do
      # The parent is loosely authored ("Identity & Access") and stored
      # normalized. The parent IS declared, so it passes the T12.2 reference
      # guard; the undeclared-parent path is covered in the drift-guard block.
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "identity-access", "name" => "Identity & Access"},
          %{"id" => "sign-up", "name" => "Sign Up", "parent" => "Identity & Access"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert %Group{id: "sign-up", parent: "identity-access"} = Enum.at(goal.groups, 1)
    end

    test "name defaults to the authored id when omitted" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "billing"}],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert [%Group{id: "billing", name: "billing"}] = goal.groups
    end

    test "a duplicate group id is a load error" do
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "identity-access", "name" => "Identity & Access"},
          %{"id" => "billing", "name" => "Billing"},
          %{"id" => "identity-access", "name" => "Identity & Access (again)"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "duplicate group id"
      assert reason =~ "identity-access"
    end

    test "a duplicate that collides only AFTER normalization is a load error" do
      # The drift guard's whole point: "Identity & Access" and "identity-access"
      # are the SAME group; declaring both must fail loudly, not silently merge.
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "identity-access", "name" => "Identity Access"},
          %{"id" => "Identity & Access", "name" => "Identity & Access"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "duplicate group id"
      assert reason =~ "identity-access"
      # The hint names the authored value and the slug it normalizes to, so the
      # author sees WHY two distinct-looking ids collided.
      assert reason =~ ~s(authored "Identity & Access" normalizes to "identity-access")
    end

    test "a group missing its id is a validation error" do
      data = %{
        "id" => "g",
        "group" => [%{"name" => "Billing"}],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ ~s(missing required key "id")
    end

    test "a non-positive group budget is a validation error" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "billing", "budget" => 0}],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ ~s(group "billing" "budget" must be a positive integer)
    end

    test "a non-array [[group]] is a validation error" do
      data = %{
        "id" => "g",
        "group" => "not-an-array",
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "[[group]] must be an array of tables"
    end

    test "the group set round-trips through the loader (load -> serialize -> load)" do
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "Identity & Access", "name" => "Identity & Access"},
          %{"id" => "sign-up", "name" => "Sign Up", "parent" => "identity-access", "budget" => 5},
          %{"id" => "billing", "name" => "Billing"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, loaded} = Loader.from_map(data)
      # Serialize the loaded goal back to the canonical map, then re-load it; the
      # group set must be stable (load -> serialize -> load is a fixpoint).
      reloaded_map = Kazi.Authoring.serialize_goal(loaded)
      assert {:ok, reloaded} = Loader.from_map(reloaded_map)

      assert reloaded.groups == loaded.groups

      # And a second round-trip is identical — the canonical form is stable.
      assert {:ok, again} =
               reloaded |> Kazi.Authoring.serialize_goal() |> Loader.from_map()

      assert again.groups == loaded.groups
    end

    test "the full [[group]] taxonomy parses from TOML text" do
      toml = """
      id = "g"

      [[group]]
      id = "Identity & Access"
      name = "Identity & Access"

      [[group]]
      id = "sign-up"
      name = "Sign Up"
      parent = "identity-access"
      budget = 5

      [[predicate]]
      id = "p"
      provider = "test_runner"
      """

      assert {:ok, goal} = Loader.from_map(Toml.decode!(toml))

      assert [
               %Group{id: "identity-access", name: "Identity & Access", parent: nil, budget: nil},
               %Group{id: "sign-up", name: "Sign Up", parent: "identity-access", budget: 5}
             ] = goal.groups
    end

    test "the checked-in grouped example loads its taxonomy" do
      path = Path.join([File.cwd!(), "priv", "examples", "grouped_taxonomy.toml"])
      assert {:ok, goal} = Loader.load(path)
      assert goal.id == "grouped-taxonomy-example"

      assert Enum.map(goal.groups, & &1.id) == ["identity-access", "sign-up", "billing"]
      assert Enum.find(goal.groups, &(&1.id == "sign-up")).parent == "identity-access"
      assert Enum.find(goal.groups, &(&1.id == "sign-up")).budget == 5
    end
  end

  describe "group references — the drift guard (T12.2, ADR-0020)" do
    test "a predicate referencing a DECLARED group id loads" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "identity-access", "name" => "Identity & Access"}],
        "predicate" => [
          %{"id" => "signup", "provider" => "browser", "group" => "identity-access"}
        ]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert [%Predicate{id: "signup", group: "identity-access"}] = goal.predicates
    end

    test "a predicate group is normalized the same way group ids are" do
      # The reference is loosely authored ("Identity & Access"); it must resolve
      # to the canonical declared slug, not fail as unknown.
      data = %{
        "id" => "g",
        "group" => [%{"id" => "identity-access", "name" => "Identity & Access"}],
        "predicate" => [
          %{"id" => "signup", "provider" => "browser", "group" => "Identity & Access"}
        ]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert [%Predicate{group: "identity-access"}] = goal.predicates
    end

    test "an UNKNOWN group id on a predicate is a load error (the typo guard)" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "identity-access", "name" => "Identity & Access"}],
        "predicate" => [
          %{"id" => "signup", "provider" => "browser", "group" => "identty-access"}
        ]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "predicate \"signup\" references unknown group"
      assert reason =~ "identty-access"
      # The error names the declared ids so the author can spot the typo.
      assert reason =~ "identity-access"
    end

    test "a group id referenced with no [[group]] declared at all is a load error" do
      data = %{
        "id" => "g",
        "predicate" => [
          %{"id" => "signup", "provider" => "browser", "group" => "identity-access"}
        ]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "references unknown group"
      assert reason =~ "declared: none"
    end

    test "an undeclared parent on a group is a load error" do
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "sign-up", "name" => "Sign Up", "parent" => "identity-access"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "group \"sign-up\" references unknown parent"
      assert reason =~ "identity-access"
    end

    test "a declared parent (forward-referenced) loads — order is irrelevant" do
      # The child is declared BEFORE its parent; validation runs once the whole
      # taxonomy is parsed, so declaration order does not matter.
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "sign-up", "name" => "Sign Up", "parent" => "identity-access"},
          %{"id" => "identity-access", "name" => "Identity & Access"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert Enum.find(goal.groups, &(&1.id == "sign-up")).parent == "identity-access"
    end

    test "a direct parent cycle is a load error" do
      # a → b → a.
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "a", "name" => "A", "parent" => "b"},
          %{"id" => "b", "name" => "B", "parent" => "a"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "cyclic parent chain"
    end

    test "a self-parent is a cycle and a load error" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "a", "name" => "A", "parent" => "a"}],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "group \"a\" has a cyclic parent chain"
    end

    test "a longer (3-node) parent cycle is a load error" do
      # a → b → c → a.
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "a", "name" => "A", "parent" => "b"},
          %{"id" => "b", "name" => "B", "parent" => "c"},
          %{"id" => "c", "name" => "C", "parent" => "a"}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "cyclic parent chain"
    end

    test "a deep acyclic chain (pillar → domain → capability) loads" do
      data = %{
        "id" => "g",
        "group" => [
          %{"id" => "pillar", "name" => "Pillar"},
          %{"id" => "domain", "name" => "Domain", "parent" => "pillar"},
          %{"id" => "capability", "name" => "Capability", "parent" => "domain"}
        ],
        "predicate" => [
          %{"id" => "p", "provider" => "test_runner", "group" => "capability"}
        ]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert Enum.map(goal.groups, & &1.parent) == [nil, "pillar", "domain"]
    end

    test "no group on a predicate (and no [[group]]) is unchanged — back-compat" do
      # The whole point of the additive field: a goal authored before T12.2 must
      # load EXACTLY as before — group is nil, no validation perturbs it.
      data = %{
        "id" => "g",
        "predicate" => [
          %{"id" => "p", "provider" => "test_runner"},
          %{"id" => "q", "provider" => "http_probe", "guard" => true}
        ]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert [%Predicate{id: "p", group: nil}] = goal.predicates
      assert [%Predicate{id: "q", group: nil}] = goal.guards
    end

    test "an empty-string predicate group is a validation error" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "identity-access", "name" => "Identity & Access"}],
        "predicate" => [%{"id" => "p", "provider" => "test_runner", "group" => ""}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ ~s(predicate "p" "group" must be a non-empty string)
    end

    test "a guard predicate may reference a declared group" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "billing", "name" => "Billing"}],
        "predicate" => [
          %{"id" => "cov", "provider" => "test_runner", "guard" => true, "group" => "billing"}
        ]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert [%Predicate{id: "cov", group: "billing"}] = goal.guards
    end

    test "a grouped predicate round-trips through serialize_goal/1" do
      data = %{
        "id" => "g",
        "group" => [%{"id" => "identity-access", "name" => "Identity & Access"}],
        "predicate" => [
          %{"id" => "signup", "provider" => "browser", "group" => "identity-access"}
        ]
      }

      assert {:ok, loaded} = Loader.from_map(data)
      reloaded_map = Kazi.Authoring.serialize_goal(loaded)
      assert {:ok, reloaded} = Loader.from_map(reloaded_map)
      assert reloaded.predicates == loaded.predicates
    end
  end
end
