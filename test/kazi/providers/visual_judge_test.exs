defmodule Kazi.Providers.VisualJudgeTest do
  @moduledoc """
  T68.8 (#1522): the visual_judge provider sends a controller-produced capture +
  hashed rubric + optional sealed reference to a PINNED model (injected here as a
  stub, never a live API) and gates on its itemized pass/fail verdict.

  Two-sided fixture: a rubric criterion "no stock tab bar; raised circular center
  control" FAILS against a stock-tab-bar frame and PASSES against the designed
  chrome — the stub judges the pixels it is handed, mirroring a real model.
  """
  use ExUnit.Case, async: false

  alias Kazi.Predicate
  alias Kazi.Providers.VisualJudge

  @moduletag :tmp_dir

  # A stub judge model injected via app-env: delegates to a per-test function so a
  # test both controls the verdict and inspects what the judge was handed.
  defmodule StubModel do
    @behaviour Kazi.Providers.VisualJudge.Model

    @impl true
    def judge(request), do: Application.fetch_env!(:kazi, :visual_judge_stub_fun).(request)
  end

  setup do
    Application.put_env(:kazi, :visual_judge_model, StubModel)

    on_exit(fn ->
      Application.delete_env(:kazi, :visual_judge_model)
      Application.delete_env(:kazi, :visual_judge_stub_fun)
    end)

    :ok
  end

  defp stub(fun) when is_function(fun, 1),
    do: Application.put_env(:kazi, :visual_judge_stub_fun, fun)

  defp predicate(config), do: Predicate.new(:looks_right, :visual_judge, config: config)

  defp capture(tmp_dir, name, bytes) do
    path = Path.join(tmp_dir, "#{name}.png")
    File.write!(path, bytes)

    %{
      name: name,
      ok: true,
      exit: 0,
      artifact_path: path,
      bytes: byte_size(bytes),
      sha256: "cafef00d",
      ran_at: "t",
      reason: nil
    }
  end

  @rubric ["no stock tab bar; raised circular center control", "primary CTA visually dominant"]

  # The stub plays the judge: it reads the pixels and applies the rubric.
  defp chrome_judge(request) do
    if String.contains?(request.screenshot, "STOCK_TABBAR") do
      {:ok,
       %{
         pass: false,
         failures: [
           %{
             criterion: "no stock tab bar; raised circular center control",
             observation: "a stock UITabBar is rendered; the raised center control is absent"
           }
         ]
       }}
    else
      {:ok, %{pass: true, failures: []}}
    end
  end

  describe "two-sided fixture (acceptance sketch)" do
    test "FAILS against a stock-tab-bar build, with the critique as the red detail", %{
      tmp_dir: tmp_dir
    } do
      stub(&chrome_judge/1)
      cap = capture(tmp_dir, "now_screen", "STOCK_TABBAR pixels…")
      ctx = %{captures: %{"now_screen" => cap}}

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric, model: "claude-opus-4-8"}),
          ctx
        )

      assert result.status == :fail
      # The itemized critique reaches the worker verbatim.
      assert [%{criterion: crit, observation: obs}] = result.evidence.failures
      assert crit == "no stock tab bar; raised circular center control"
      assert obs =~ "raised center control is absent"
      assert result.evidence.critique == [crit <> ": " <> obs]
      # Provenance: pinned model + hashed rubric.
      assert result.evidence.model == "claude-opus-4-8"
      assert is_binary(result.evidence.rubric_sha256)
    end

    test "PASSES against the designed chrome", %{tmp_dir: tmp_dir} do
      stub(&chrome_judge/1)
      cap = capture(tmp_dir, "now_screen", "DESIGNED_CHROME raised circular control pixels…")
      ctx = %{captures: %{"now_screen" => cap}}

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric, model: "claude-opus-4-8"}),
          ctx
        )

      assert result.status == :pass
      assert result.evidence.pass == true
    end
  end

  describe "the judge sees only pixels + rubric" do
    test "the request carries screenshot bytes, references, and the rubric — no workspace text",
         %{
           tmp_dir: tmp_dir
         } do
      test_pid = self()

      stub(fn request ->
        send(test_pid, {:judged, request})
        {:ok, %{pass: true, failures: []}}
      end)

      ref = Path.join(tmp_dir, "mockup.png")
      File.write!(ref, "REFERENCE pixels")
      cap = capture(tmp_dir, "now_screen", "SCREENSHOT pixels")

      ctx = %{captures: %{"now_screen" => cap}, workspace: tmp_dir}

      VisualJudge.evaluate(
        predicate(%{
          capture: "now_screen",
          rubric: @rubric,
          model: "claude-opus-4-8",
          reference: "mockup.png",
          votes: 3
        }),
        ctx
      )

      assert_received {:judged, request}
      assert request.screenshot == "SCREENSHOT pixels"
      assert request.references == ["REFERENCE pixels"]
      assert request.rubric == @rubric
      assert request.model == "claude-opus-4-8"
      assert request.votes == 3
      assert request.temperature == 0
      # The request shape has no workspace-text channel a worker could inject.
      refute Map.has_key?(request, :workspace)
      refute Map.has_key?(request, :source)
    end
  end

  describe "honest verdicts (never green)" do
    test "a capture missing from the evidence store is :unknown, never green", %{tmp_dir: _} do
      stub(fn _ -> flunk("must not call the model when there is no capture") end)

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric, model: "claude-opus-4-8"}),
          %{captures: %{}}
        )

      assert result.status == :unknown
      assert result.evidence.reason == {:capture_not_found, "now_screen"}
    end

    test "a capture that RAN but failed (crash/blank) is :unknown" do
      stub(fn _ -> flunk("must not judge a failed capture") end)
      failed = %{name: "now_screen", ok: false, reason: :no_artifact, artifact_path: nil}

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric, model: "claude-opus-4-8"}),
          %{captures: %{"now_screen" => failed}}
        )

      assert result.status == :unknown
      assert result.evidence.reason == {:capture_failed, :no_artifact}
    end

    test "an unparseable model verdict is :unknown, never green", %{tmp_dir: tmp_dir} do
      stub(fn _ -> {:ok, %{verdict: "looks fine to me"}} end)
      cap = capture(tmp_dir, "now_screen", "pixels")

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric, model: "claude-opus-4-8"}),
          %{captures: %{"now_screen" => cap}}
        )

      assert result.status == :unknown
      assert result.evidence.reason == :unparseable_verdict
    end

    test "a failed model call is :unknown (cannot judge)", %{tmp_dir: tmp_dir} do
      stub(fn _ -> {:error, :timeout} end)
      cap = capture(tmp_dir, "now_screen", "pixels")

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric, model: "claude-opus-4-8"}),
          %{captures: %{"now_screen" => cap}}
        )

      assert result.status == :unknown
      assert result.evidence.reason == {:model_call_failed, :timeout}
    end

    test "an unreadable reference image is :unknown", %{tmp_dir: tmp_dir} do
      stub(fn _ -> flunk("must not judge without the reference") end)
      cap = capture(tmp_dir, "now_screen", "pixels")

      result =
        VisualJudge.evaluate(
          predicate(%{
            capture: "now_screen",
            rubric: @rubric,
            model: "claude-opus-4-8",
            reference: "missing.png"
          }),
          %{captures: %{"now_screen" => cap}, workspace: tmp_dir}
        )

      assert result.status == :unknown
      assert match?({:reference_unreadable, "missing.png", _}, result.evidence.reason)
    end
  end

  describe "misconfiguration + unwired transport are :error (not failing work)" do
    test "no model transport wired is :error, never green (default UnconfiguredModel)", %{
      tmp_dir: tmp_dir
    } do
      # No stub: fall back to the real default (UnconfiguredModel).
      Application.delete_env(:kazi, :visual_judge_model)
      cap = capture(tmp_dir, "now_screen", "pixels")

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric, model: "claude-opus-4-8"}),
          %{captures: %{"now_screen" => cap}}
        )

      assert result.status == :error
      assert result.evidence.reason == :model_not_configured
    end

    test "no capture configured is :error" do
      result =
        VisualJudge.evaluate(predicate(%{rubric: @rubric, model: "claude-opus-4-8"}), %{
          captures: %{}
        })

      assert result.status == :error
      assert result.evidence.reason == :no_capture_configured
    end

    test "no rubric is :error", %{tmp_dir: tmp_dir} do
      cap = capture(tmp_dir, "now_screen", "pixels")

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", model: "claude-opus-4-8"}),
          %{captures: %{"now_screen" => cap}}
        )

      assert result.status == :error
      assert result.evidence.reason == :no_rubric_configured
    end

    test "no model is :error", %{tmp_dir: tmp_dir} do
      cap = capture(tmp_dir, "now_screen", "pixels")

      result =
        VisualJudge.evaluate(
          predicate(%{capture: "now_screen", rubric: @rubric}),
          %{captures: %{"now_screen" => cap}}
        )

      assert result.status == :error
      assert result.evidence.reason == :no_model_configured
    end
  end
end
