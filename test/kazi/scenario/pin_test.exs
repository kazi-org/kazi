defmodule Kazi.Scenario.PinTest do
  use ExUnit.Case, async: true

  alias Kazi.Scenario.Pin

  @scenario_sha String.duplicate("a", 64)
  @other_sha String.duplicate("b", 64)

  # The scenario shape `Kazi.Scenario.Source.extract/2` (T49.2) produces. Pin
  # never calls Source; the sha arrives through the `:sha_fun` seam.
  defp scenario do
    %{
      feature: "Personal access tokens",
      scenario: "User can create and download a PAT",
      steps: [
        %{keyword: "Given", text: "I am signed in", class: :given},
        %{keyword: "When", text: "I create a token", class: :when},
        %{keyword: "Then", text: "the token value is shown", class: :then}
      ]
    }
  end

  defp golden_json do
    %{
      "pin_version" => 1,
      "spec" => "docs/specs/pat.feature",
      "scenario" => "User can create and download a PAT",
      "scenario_sha" => @scenario_sha,
      "surface" => "browser",
      "minted" => %{"commit" => "0f1e2d3c4b5a"},
      "inputs" => %{"pat_name" => "unique_slug"},
      "trace" => %{
        "url" => "/settings/tokens",
        "steps" => [
          %{"action" => "click", "selector" => "#new-token"},
          %{"action" => "type", "selector" => "#name", "text" => "{{pat_name}}"},
          %{"action" => "click", "selector" => "#generate"}
        ],
        "assertions" => [
          %{"type" => "visible", "selector" => "#token-value"},
          %{"type" => "text", "selector" => "#token-name", "equals" => "{{pat_name}}"}
        ],
        "timeout_ms" => 30_000,
        "samples" => 1
      },
      "map" => [
        %{"step" => "I am signed in", "steps" => [], "assertions" => []},
        %{"step" => "I create a token", "steps" => [0, 1, 2], "assertions" => []},
        %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 1]}
      ]
    }
  end

  defp parse!(json) do
    {:ok, pin} = json |> Jason.encode!() |> Pin.parse()
    pin
  end

  defp validate_json(json) do
    Pin.validate(parse!(json), scenario(), sha_fun: fn _scenario -> @scenario_sha end)
  end

  defp patch(json, patches) do
    Enum.reduce(patches, json, fn {path, value}, acc -> put_in(acc, path, value) end)
  end

  describe "parse/1" do
    test "decodes every contract field, keeping trace and map verbatim" do
      pin = parse!(golden_json())

      assert pin.pin_version == 1
      assert pin.spec == "docs/specs/pat.feature"
      assert pin.scenario == "User can create and download a PAT"
      assert pin.scenario_sha == @scenario_sha
      assert pin.surface == "browser"
      assert pin.minted == %{"commit" => "0f1e2d3c4b5a"}
      assert pin.inputs == %{"pat_name" => "unique_slug"}
      # trace stays byte-for-byte the surface provider's own config vocabulary
      assert pin.trace == golden_json()["trace"]
      assert pin.map == golden_json()["map"]
    end

    test "defaults the optional containers so a sparse pin still validates deterministically" do
      {:ok, pin} = Pin.parse(~s({"pin_version": 1}))

      assert pin.minted == %{}
      assert pin.inputs == %{}
      assert pin.trace == %{}
      assert pin.map == []
    end

    test "malformed JSON is a named parse error, not a raise" do
      assert {:error, {:malformed_json, detail}} = Pin.parse("{not json")
      assert is_binary(detail.detail)
    end

    test "a non-object JSON document is a named parse error" do
      assert {:error, {:malformed_pin, %{expected: :object, found: :list}}} = Pin.parse("[1,2]")
    end
  end

  describe "validate/3 -- the golden pin" do
    test "a valid pin returns :ok" do
      assert :ok = validate_json(golden_json())
    end

    test "reads the sha off the scenario map when no :sha_fun is injected" do
      pin = parse!(golden_json())
      assert :ok = Pin.validate(pin, Map.put(scenario(), :sha, @scenario_sha))
    end

    test "raises when neither a :sha_fun nor a scenario :sha is supplied" do
      pin = parse!(golden_json())

      assert_raise ArgumentError, ~r/sha_fun/, fn ->
        Pin.validate(pin, scenario())
      end
    end
  end

  # Table-driven: each row violates exactly ONE rule and must surface exactly
  # that rule's named reason -- no collateral reasons.
  @invalid_cases [
    {:pin_version, "pin_version is not 1", [{["pin_version"], 2}]},
    {:stale, "scenario_sha does not match the current Scenario",
     [{["scenario_sha"], String.duplicate("b", 64)}]},
    {:bad_surface, "surface is outside browser|cli", [{["surface"], "desktop"}]},
    {:unknown_trace_key, "trace carries a key outside the surface whitelist",
     [{["trace", "screenshot"], "shot.png"}]},
    {:unmapped_when, "a When-class step maps to zero trace steps",
     [
       {["map"],
        [
          %{"step" => "I am signed in", "steps" => [], "assertions" => []},
          %{"step" => "I create a token", "steps" => [], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 1]}
        ]}
     ]},
    {:unmapped_when, "a When-class step has no map entry at all",
     [
       {["map"],
        [
          %{"step" => "I am signed in", "steps" => [], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 1]}
        ]}
     ]},
    {:unmapped_then, "a Then-class step maps to zero trace assertions",
     [
       {["map"],
        [
          %{"step" => "I am signed in", "steps" => [], "assertions" => []},
          %{"step" => "I create a token", "steps" => [0, 1, 2], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => []}
        ]}
     ]},
    {:unmapped_then, "a Then-class step has no map entry at all",
     [
       {["map"],
        [
          %{"step" => "I am signed in", "steps" => [], "assertions" => []},
          %{"step" => "I create a token", "steps" => [0, 1, 2], "assertions" => []}
        ]}
     ]},
    {:index_out_of_range, "a step index points past the end of trace.steps",
     [
       {["map"],
        [
          %{"step" => "I am signed in", "steps" => [], "assertions" => []},
          %{"step" => "I create a token", "steps" => [0, 1, 9], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 1]}
        ]}
     ]},
    {:index_out_of_range, "an assertion index points past the end of trace.assertions",
     [
       {["map"],
        [
          %{"step" => "I am signed in", "steps" => [], "assertions" => []},
          %{"step" => "I create a token", "steps" => [0, 1, 2], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 7]}
        ]}
     ]},
    {:index_out_of_range, "a negative index is out of range",
     [
       {["map"],
        [
          %{"step" => "I am signed in", "steps" => [], "assertions" => []},
          %{"step" => "I create a token", "steps" => [-1], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 1]}
        ]}
     ]},
    {:uncovered_placeholder, "a trace step interpolates a name absent from inputs",
     [
       {["trace", "steps"],
        [
          %{"action" => "click", "selector" => "#new-token"},
          %{"action" => "type", "selector" => "#name", "text" => "{{unknown_name}}"},
          %{"action" => "click", "selector" => "#generate"}
        ]},
       {["trace", "assertions"],
        [
          %{"type" => "visible", "selector" => "#token-value"},
          %{"type" => "text", "selector" => "#token-name", "equals" => "static"}
        ]}
     ]},
    {:uncovered_placeholder, "a trace assertion interpolates a name absent from inputs",
     [
       {["trace", "assertions"],
        [
          %{"type" => "visible", "selector" => "#token-value"},
          %{"type" => "text", "selector" => "#token-name", "equals" => "{{other_name}}"}
        ]}
     ]}
  ]

  describe "validate/3 -- one rule violated at a time" do
    for {expected, label, patches} <- @invalid_cases do
      test "reports #{expected} when #{label}" do
        json = patch(golden_json(), unquote(Macro.escape(patches)))

        assert {:error, reasons} = validate_json(json)

        tags = reasons |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        assert tags == [unquote(expected)],
               "expected only #{unquote(expected)}, got #{inspect(reasons)}"
      end
    end
  end

  describe "validate/3 -- reason detail" do
    test "pin_version carries expected vs found" do
      json = patch(golden_json(), [{["pin_version"], 7}])
      assert {:error, [{:pin_version, %{expected: 1, found: 7}}]} = validate_json(json)
    end

    test "a changed Scenario is exactly {:stale, :spec_changed}" do
      json = patch(golden_json(), [{["scenario_sha"], @other_sha}])
      assert {:error, [{:stale, :spec_changed}]} = validate_json(json)
    end

    test "bad_surface names what was found and what is allowed" do
      json = patch(golden_json(), [{["surface"], "desktop"}])
      assert {:error, [{:bad_surface, detail}]} = validate_json(json)
      assert detail.found == "desktop"
      assert detail.allowed == ["browser", "cli"]
    end

    test "unknown_trace_key names the key, the surface and the whitelist" do
      json = patch(golden_json(), [{["trace", "screenshot"], "shot.png"}])
      assert {:error, [{:unknown_trace_key, detail}]} = validate_json(json)
      assert detail.key == "screenshot"
      assert detail.surface == "browser"
      assert "url" in detail.allowed
    end

    test "unmapped_when names the offending Gherkin step" do
      json =
        patch(golden_json(), [
          {["map"],
           [
             %{"step" => "I create a token", "steps" => [], "assertions" => []},
             %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 1]}
           ]}
        ])

      assert {:error, [{:unmapped_when, detail}]} = validate_json(json)
      assert detail.step == "When I create a token"
    end

    test "index_out_of_range names the list, the index and the trace length" do
      json =
        patch(golden_json(), [
          {["map"],
           [
             %{"step" => "I create a token", "steps" => [9], "assertions" => []},
             %{"step" => "the token value is shown", "steps" => [], "assertions" => [0, 1]}
           ]}
        ])

      assert {:error, [{:index_out_of_range, detail}]} = validate_json(json)
      assert detail.list == "steps"
      assert detail.index == 9
      assert detail.count == 3
    end

    test "uncovered_placeholder names the placeholder" do
      json =
        patch(golden_json(), [
          {["trace", "assertions"],
           [
             %{"type" => "visible", "selector" => "#token-value"},
             %{"type" => "text", "selector" => "#t", "equals" => "{{other_name}}"}
           ]}
        ])

      assert {:error, [{:uncovered_placeholder, %{name: "other_name"}}]} = validate_json(json)
    end

    test "every violated rule is reported, not just the first" do
      json = patch(golden_json(), [{["pin_version"], 3}, {["trace", "screenshot"], "x.png"}])

      assert {:error, reasons} = validate_json(json)
      tags = reasons |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert tags == [:pin_version, :unknown_trace_key]
    end
  end

  describe "validate/3 -- step matching" do
    test "a map entry may carry the bare step text or the full keyword line" do
      json =
        patch(golden_json(), [
          {["map"],
           [
             %{"step" => "When I create a token", "steps" => [0], "assertions" => []},
             %{"step" => "Then the token value is shown", "steps" => [], "assertions" => [0]}
           ]}
        ])

      assert :ok = validate_json(json)
    end

    test "step matching tolerates whitespace churn" do
      json =
        patch(golden_json(), [
          {["map"],
           [
             %{"step" => "  I create   a token  ", "steps" => [0], "assertions" => []},
             %{"step" => "the token value is shown", "steps" => [], "assertions" => [0]}
           ]}
        ])

      assert :ok = validate_json(json)
    end

    test "Given-class steps need no mapping" do
      json =
        patch(golden_json(), [
          {["map"],
           [
             %{"step" => "I create a token", "steps" => [0], "assertions" => []},
             %{"step" => "the token value is shown", "steps" => [], "assertions" => [0]}
           ]}
        ])

      assert :ok = validate_json(json)
    end
  end

  describe "validate/3 -- cli surface" do
    setup do
      json =
        golden_json()
        |> Map.put("surface", "cli")
        |> Map.put("inputs", %{"goal_name" => "unique_slug"})
        |> Map.put("trace", %{
          "args" => ["apply", "{{goal_name}}.goal.toml"],
          "script" => [%{"args" => ["version"]}, %{"args" => ["apply", "hello.goal.toml"]}],
          "assertions" => [%{"type" => "exit_code", "equals" => 0}],
          "timeout_ms" => 10_000,
          "samples" => 1
        })
        |> Map.put("map", [
          %{"step" => "I create a token", "steps" => [0, 1], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0]}
        ])

      %{json: json}
    end

    test "a cli pin maps When-class steps onto trace.script", %{json: json} do
      assert :ok = validate_json(json)
    end

    test "the cli whitelist rejects a browser-only key", %{json: json} do
      json = put_in(json, ["trace", "url"], "/settings")

      assert {:error, [{:unknown_trace_key, detail}]} = validate_json(json)
      assert detail.key == "url"
      assert detail.surface == "cli"
    end

    test "cli step indices range over trace.script, not trace.steps", %{json: json} do
      json =
        put_in(json, ["map"], [
          %{"step" => "I create a token", "steps" => [5], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0]}
        ])

      assert {:error, [{:index_out_of_range, detail}]} = validate_json(json)
      assert detail.list == "script"
      assert detail.count == 2
    end
  end

  defp classify(contents, pin, scenario) do
    Pin.classify(contents, pin, scenario, sha_fun: fn _scenario -> @scenario_sha end)
  end

  describe "classify/4" do
    test "nil contents classify :unpinned" do
      assert :unpinned = classify(nil, nil, scenario())
    end

    test "nil contents classify :unpinned even when a pin is somehow supplied" do
      assert :unpinned = classify(nil, parse!(golden_json()), scenario())
    end

    test "a valid, current pin classifies :pinned" do
      json = golden_json()
      assert :pinned = classify(Jason.encode!(json), parse!(json), scenario())
    end

    test "a sha mismatch classifies {:stale, :spec_changed}" do
      json = patch(golden_json(), [{["scenario_sha"], @other_sha}])
      assert {:stale, :spec_changed} = classify(Jason.encode!(json), parse!(json), scenario())
    end

    test "a structurally vacuous pin classifies {:invalid, reasons}" do
      json =
        patch(golden_json(), [
          {["map"],
           [
             %{"step" => "I create a token", "steps" => [0], "assertions" => []},
             %{"step" => "the token value is shown", "steps" => [], "assertions" => []}
           ]}
        ])

      assert {:invalid, [{:unmapped_then, _}]} =
               classify(Jason.encode!(json), parse!(json), scenario())
    end

    test "a stale spec wins over other invalidity -- re-demonstration supersedes repair" do
      json =
        patch(golden_json(), [
          {["scenario_sha"], @other_sha},
          {["pin_version"], 9}
        ])

      assert {:stale, :spec_changed} = classify(Jason.encode!(json), parse!(json), scenario())
    end

    test "an unparseable pin file classifies {:invalid, reasons}" do
      contents = "{not json"
      {:error, reason} = Pin.parse(contents)

      assert {:invalid, [{:malformed_json, _}]} = classify(contents, {:error, reason}, scenario())
    end

    test "classify/3 defaults its opts and reads the sha off the scenario map" do
      json = golden_json()

      assert :pinned =
               Pin.classify(
                 Jason.encode!(json),
                 parse!(json),
                 Map.put(scenario(), :sha, @scenario_sha)
               )
    end
  end

  describe "purity (ADR-0064: evaluation is deterministic; callers own I/O)" do
    test "the compiled module makes no File, IO, or filesystem calls" do
      path = :code.which(Pin)
      {:ok, {_mod, [imports: imports]}} = :beam_lib.chunks(path, [:imports])

      offenders =
        Enum.filter(imports, fn {mod, _fun, _arity} ->
          mod in [File, IO, :file, :filelib, :io, File.Stream, Path]
        end)

      assert offenders == [], "expected no I/O calls, found: #{inspect(offenders)}"
    end

    test "the source carries no File/IO call sites" do
      source = File.read!("lib/kazi/scenario/pin.ex")
      refute source =~ ~r/\bFile\./
      refute source =~ ~r/\bIO\./
    end
  end
end
