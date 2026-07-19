defmodule Kazi.Providers.RenderProof do
  @moduledoc """
  The `:render_proof` predicate provider (ADR-0081, #1521): turns "it actually
  rendered" into an objective predicate over a CONTROLLER-produced capture.

  A UI goal is gamed by presence — code that grep-matches an id but never renders.
  `render_proof` consumes a capture recipe's artifact (produced by the controller,
  not the worker — see `Kazi.Sink.Captures`) and passes only when the artifact is
  a plausible non-blank, non-crash frame:

    * `:pass` — the named capture succeeded AND the artifact exceeds a byte-size
      floor AND a color-entropy floor (distinct byte values, a dependency-free
      "not a solid fill" heuristic).
    * `:fail` — the capture failed (app crashed on launch, wrote nothing) or the
      artifact is blank / degenerate / a solid crash-screen fill. This is real
      failing work: a goal whose code compiles but never renders CANNOT converge.
    * `:error` — the capture machinery itself was unavailable (the goal declared
      no matching capture, or `context[:captures]` was not threaded). Infra, never
      failing work (ADR-0002) — so a mis-wired run does not dispatch a fixer.

  ## Config (`Kazi.Predicate.config`)

    * `:capture` — the capture name to consume. Equivalently `:input` of the form
      `"capture:<name>"`.
    * `:min_bytes` — artifact byte-size floor (default `1024`).
    * `:min_distinct_bytes` — distinct-byte-value floor over the artifact, the
      color-entropy proxy (default `16`). A blank/solid image compresses to very
      few distinct bytes.

  ## Context

  Reads `context[:captures]` — the `%{name => capture_result}` map the loop threads
  from `Kazi.Sink.Captures.run/2`. The artifact bytes are re-read from the
  capture's controller-owned `artifact_path` for the entropy check.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  @default_min_bytes 1024
  @default_min_distinct_bytes 16

  @impl true
  @spec evaluate(Predicate.t(), map()) :: PredicateResult.t()
  def evaluate(%Predicate{config: config}, context) do
    captures = Map.get(context, :captures, %{})

    case resolve_capture_name(config) do
      nil ->
        PredicateResult.error(%{reason: :no_capture_configured})

      name ->
        case Map.get(captures, name) do
          nil -> PredicateResult.error(%{reason: :capture_not_found, capture: name})
          result -> judge(result, config)
        end
    end
  end

  # A capture that could not run at all is infra (:error); a capture that RAN but
  # produced a failed/blank/degenerate frame is real failing work (:fail).
  defp judge(%{ok: false, reason: reason} = result, _config)
       when reason in [:launch_unavailable, :reset_unavailable] do
    PredicateResult.error(evidence(result, %{reason: reason}))
  end

  defp judge(%{ok: false} = result, _config) do
    PredicateResult.fail(evidence(result, %{reason: result[:reason] || :capture_failed}))
  end

  defp judge(%{ok: true} = result, config) do
    min_bytes = Map.get(config, :min_bytes, @default_min_bytes)
    min_distinct = Map.get(config, :min_distinct_bytes, @default_min_distinct_bytes)

    with {:ok, bytes} <- read_artifact(result),
         :ok <- check_size(bytes, min_bytes),
         :ok <- check_entropy(bytes, min_distinct) do
      PredicateResult.pass(evidence(result, %{rendered: true}))
    else
      {:error, reason, extra} ->
        PredicateResult.fail(evidence(result, Map.put(extra, :reason, reason)))
    end
  end

  defp read_artifact(%{artifact_path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, :artifact_unreadable, %{}}
    end
  end

  defp read_artifact(_result), do: {:error, :no_artifact_path, %{}}

  defp check_size(bytes, min_bytes) do
    if byte_size(bytes) >= min_bytes,
      do: :ok,
      else: {:error, :below_size_floor, %{bytes: byte_size(bytes), min_bytes: min_bytes}}
  end

  # Color-entropy proxy: a blank or solid-fill frame compresses to very few
  # distinct byte values; a real rendered screen has many. Dependency-free (no
  # image decode) — a conservative "not a solid fill" floor, not a pixel judge.
  defp check_entropy(bytes, min_distinct) do
    distinct = bytes |> :binary.bin_to_list() |> Enum.uniq() |> length()

    if distinct >= min_distinct,
      do: :ok,
      else:
        {:error, :below_entropy_floor, %{distinct_bytes: distinct, min_distinct: min_distinct}}
  end

  # `capture = "name"` or `input = "capture:name"`; the latter is the generic
  # cross-artifact reference form ADR-0081 §4 names.
  defp resolve_capture_name(config) do
    cond do
      is_binary(config[:capture]) and config[:capture] != "" -> config[:capture]
      is_binary(config[:input]) -> parse_input(config[:input])
      true -> nil
    end
  end

  defp parse_input("capture:" <> name) when name != "", do: name
  defp parse_input(_other), do: nil

  # The evidence a fixer / reviewer needs: the capture's provenance (path, hash,
  # size, exit) plus the specific render-proof reason.
  defp evidence(result, extra) do
    Map.merge(
      %{
        capture: result[:name],
        artifact_path: result[:artifact_path],
        sha256: result[:sha256],
        capture_bytes: result[:bytes],
        capture_exit: result[:exit]
      },
      extra
    )
  end
end
