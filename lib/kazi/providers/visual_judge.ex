defmodule Kazi.Providers.VisualJudge do
  @moduledoc """
  The `:visual_judge` predicate provider (T68.8, #1522): pinned strong-model
  screenshot judgment against a hashed rubric and optional design reference,
  producing a STRUCTURED, itemized verdict whose critique is the red detail.

  Deterministic visual predicates (greps, pixel/zone checks) bound gaming but
  cannot judge whether a UI is *good* — hierarchy, restraint, fidelity to an
  approved design's structure. `visual_judge` adds that judgment while KEEPING
  objective termination: pass/fail against a pinned model id + a content-hashed
  rubric + fixed decode settings (temperature 0) is as reproducible as any
  external-tool predicate. It is NOT a "beauty score" — the verdict is itemized
  pass/fail (a scalar invites threshold-shopping and cannot converge).

  ## What it judges, and what it never sees

  The provider sends the judge model ONLY pixels + the author's rubric:

    * the **screenshot** — a CONTROLLER-produced capture (ADR-0081) resolved from
      `context[:captures]` by name, never a worker-chosen workspace path;
    * optional **reference image(s)** — approved mockup crops, sealed inputs
      (ADR-0080) read from the workspace;
    * the **rubric** — a fixed pass/fail checklist authored at plan time.

  It never reads workspace source text, so a converging worker cannot prompt-inject
  the judge through code or comments. The rubric and model id live in the goal-file
  (implicitly sealed, ADR-0080) and reference images are declared `sealed_inputs`,
  so both the judged pixels' bar and the reference are tamper-evident: an edit
  mid-run flips the run `tampered`, never green.

  ## Config (`Kazi.Predicate.config`)

    * `:capture` — the capture name to judge (the screenshot). Equivalently
      `:input` of the form `"capture:<name>"`. Required.
    * `:rubric` — a non-empty list of criterion strings (the pass/fail checklist).
      Required. A single string is accepted and wrapped.
    * `:model` — the pinned judge model id, recorded in the goal-file. Required.
    * `:reference` — optional workspace-relative path (or list of paths) to the
      reference image(s). Declare these under `[seal] sealed_inputs` so they are
      tamper-evident.
    * `:votes` — optional N-vote majority sample count (default 1), passed to the
      model transport.

  ## Verdict mapping (honest verdicts, ADR-0002)

    * `:pass` — the model returned `pass: true`.
    * `:fail` — the model returned `pass: false`; the itemized `failures`
      (`criterion` + `observation`) ride in the evidence as the actionable
      critique the worker fixes next iteration.
    * `:unknown` — the judge could not reach a verdict from valid inputs: the
      capture is missing / failed / unreadable, a reference is unreadable, the
      model call failed, or its response was unparseable. Red, never green — a
      capture the loop never produced can never pass.
    * `:error` — provider MISCONFIGURATION or unwired infra (ADR-0002): no capture
      / rubric / model configured, or no model transport wired
      (`:model_not_configured`). Not failing work, so it does not dispatch a fixer.

  ## Context

  Reads `context[:captures]` (the `%{name => capture_result}` map the loop threads
  from `Kazi.Sink.Captures`) and `context[:workspace]` (to resolve reference
  images). The model transport is resolved from
  `Application.get_env(:kazi, :visual_judge_model, Kazi.Providers.VisualJudge.UnconfiguredModel)`
  — an injectable seam (`Kazi.Providers.VisualJudge.Model`) so the judgment is
  hermetically testable with a recorded verdict and no live API.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.VisualJudge.UnconfiguredModel

  @model_impl_key :visual_judge_model
  @default_votes 1

  @impl true
  @spec evaluate(Predicate.t(), map()) :: PredicateResult.t()
  def evaluate(%Predicate{config: config}, context) do
    with {:ok, name} <- fetch_capture_name(config),
         {:ok, rubric} <- fetch_rubric(config),
         {:ok, model} <- fetch_model(config),
         {:ok, capture} <- resolve_capture(context, name),
         {:ok, screenshot} <- read_capture_artifact(capture),
         {:ok, references} <- read_references(config, context) do
      request = %{
        screenshot: screenshot,
        references: references,
        rubric: rubric,
        model: model,
        votes: votes(config),
        temperature: 0
      }

      decide(call_model(request), rubric, model, capture)
    else
      {:error, kind, reason} -> unresolved(kind, reason)
    end
  end

  # =============================================================================
  # Input resolution — misconfig (:error) vs cannot-judge (:unknown)
  # =============================================================================

  defp fetch_capture_name(config) do
    case resolve_capture_name(config) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :config, :no_capture_configured}
    end
  end

  defp fetch_rubric(config) do
    case normalize_rubric(config[:rubric]) do
      [] -> {:error, :config, :no_rubric_configured}
      rubric -> {:ok, rubric}
    end
  end

  defp fetch_model(config) do
    case config[:model] do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, :config, :no_model_configured}
    end
  end

  # A capture the loop never produced (name absent) or that RAN but failed
  # (ok: false — app crashed / wrote nothing) leaves nothing to judge: :unknown,
  # never green. This is distinct from render_proof, which owns the "did it
  # render" verdict; the judge simply cannot proceed without pixels.
  defp resolve_capture(context, name) do
    captures = Map.get(context, :captures, %{})

    case Map.get(captures, name) do
      %{ok: true} = capture -> {:ok, capture}
      %{ok: false} = capture -> {:error, :judge, {:capture_failed, capture[:reason]}}
      nil -> {:error, :judge, {:capture_not_found, name}}
      _ -> {:error, :judge, {:capture_malformed, name}}
    end
  end

  defp read_capture_artifact(%{artifact_path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, :judge, {:artifact_unreadable, reason}}
    end
  end

  defp read_capture_artifact(_capture), do: {:error, :judge, :no_artifact_path}

  # Reference images are sealed workspace inputs (ADR-0080); read their bytes to
  # send to the judge. Absent config => no references (the rubric-only mode).
  defp read_references(config, context) do
    workspace = Map.get(context, :workspace) || File.cwd!()

    config
    |> reference_paths()
    |> Enum.reduce_while({:ok, []}, fn rel, {:ok, acc} ->
      case File.read(Path.join(workspace, rel)) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | acc]}}
        {:error, reason} -> {:halt, {:error, :judge, {:reference_unreadable, rel, reason}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  # =============================================================================
  # Model dispatch + verdict mapping
  # =============================================================================

  defp call_model(request) do
    impl = Application.get_env(:kazi, @model_impl_key, UnconfiguredModel)
    impl.judge(request)
  rescue
    error -> {:error, {:model_raised, Exception.message(error)}}
  end

  defp decide({:ok, %{pass: true}} = _verdict, rubric, model, capture) do
    PredicateResult.pass(base_evidence(rubric, model, capture, %{pass: true, failures: []}))
  end

  defp decide({:ok, %{pass: false, failures: failures}}, rubric, model, capture)
       when is_list(failures) do
    normalized = normalize_failures(failures)

    PredicateResult.fail(
      base_evidence(rubric, model, capture, %{
        pass: false,
        # The itemized critique IS the red detail (#1522): each rubric criterion
        # the judge found violated, with the observation the worker acts on.
        failures: normalized,
        critique: critique_lines(normalized)
      })
    )
  end

  # A malformed verdict (no boolean pass, or pass:false without a failures list)
  # is :unknown — the judge produced something we cannot trust as a pass/fail, so
  # it is honestly "cannot judge", never green.
  defp decide({:ok, other}, rubric, model, capture) do
    PredicateResult.unknown(
      base_evidence(rubric, model, capture, %{reason: :unparseable_verdict, raw: inspect(other)})
    )
  end

  # No transport wired is infra the author must fix (:error); any other transport
  # failure is "could not judge" (:unknown) — neither is failing work the worker
  # produced.
  defp decide({:error, :model_not_configured}, rubric, model, capture) do
    PredicateResult.error(base_evidence(rubric, model, capture, %{reason: :model_not_configured}))
  end

  defp decide({:error, reason}, rubric, model, capture) do
    PredicateResult.unknown(
      base_evidence(rubric, model, capture, %{reason: {:model_call_failed, reason}})
    )
  end

  # Input-resolution failures: config problems are :error (misconfig), everything
  # else is :unknown (the judge could not get valid inputs).
  defp unresolved(:config, reason), do: PredicateResult.error(%{reason: reason})
  defp unresolved(:judge, reason), do: PredicateResult.unknown(%{reason: reason})

  # =============================================================================
  # Evidence + helpers
  # =============================================================================

  # Provenance a reviewer/fixer needs: the pinned model, the rubric's content hash
  # (the "hashed rubric" of #1522 — a stable fingerprint of the bar), and the
  # capture's controller-owned identity (name + sha256). The rubric TEXT rides
  # too so the critique is self-contained.
  defp base_evidence(rubric, model, capture, extra) do
    Map.merge(
      %{
        model: model,
        rubric: rubric,
        rubric_sha256: rubric_hash(rubric),
        capture: capture[:name],
        capture_sha256: capture[:sha256],
        artifact_path: capture[:artifact_path]
      },
      extra
    )
  end

  defp rubric_hash(rubric) do
    rubric
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_failures(failures) do
    Enum.map(failures, fn f ->
      %{
        criterion: to_string(fetch_any(f, [:criterion, "criterion"], "")),
        observation: to_string(fetch_any(f, [:observation, "observation"], ""))
      }
    end)
  end

  defp critique_lines(failures) do
    Enum.map(failures, fn %{criterion: c, observation: o} -> "#{c}: #{o}" end)
  end

  defp fetch_any(map, keys, default) do
    Enum.find_value(keys, default, fn k ->
      case Map.get(map, k) do
        nil -> nil
        v -> v
      end
    end)
  end

  defp normalize_rubric(rubric) when is_binary(rubric) and rubric != "", do: [rubric]

  defp normalize_rubric(rubric) when is_list(rubric) do
    rubric
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_rubric(_), do: []

  defp reference_paths(config) do
    case config[:reference] do
      path when is_binary(path) and path != "" -> [path]
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  defp votes(config) do
    case config[:votes] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_votes
    end
  end

  # `capture = "name"` or `input = "capture:name"` — the same reference forms
  # render_proof accepts (ADR-0081 §4).
  defp resolve_capture_name(config) do
    cond do
      is_binary(config[:capture]) and config[:capture] != "" -> config[:capture]
      is_binary(config[:input]) -> parse_input(config[:input])
      true -> nil
    end
  end

  defp parse_input("capture:" <> name) when name != "", do: name
  defp parse_input(_other), do: nil
end
