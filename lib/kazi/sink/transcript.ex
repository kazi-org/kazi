defmodule Kazi.Sink.Transcript do
  @moduledoc """
  The per-run `transcript.jsonl` sink (T46.3, ADR-0057 decision 3): tees the
  inner-harness stream to disk as newline-delimited JSON, redacted before it
  ever touches a file the operator (or a later `kazi dashboard` "transcript
  peek" view) reads.

  This is a **passive tee**: `tee/3` is called AFTER a harness dispatch has
  already produced its captured output, purely as a side effect. It never
  raises into the caller and never changes what the dispatch returns — the
  dispatch result is byte-identical whether the tee is configured or not
  (`Kazi.Harness.CliAdapter`'s contract).

  ## Event shape

  The harness's raw captured output (stdout+stderr, `Kazi.HarnessAdapter`'s
  `:output`) is split into events, one per line:

    * a line that parses as a JSON object (Claude's `--output-format
      stream-json` tool-call/text events, and any other structured-per-line
      harness output) is redacted field-by-field and appended as-is;
    * any other line is wrapped as `%{"type" => "text", "text" => line}` before
      redaction, so plain stdout/stderr chunks (CLI-profile harnesses with no
      structured stream) still land as valid JSONL.

  Redaction runs through `Kazi.Redaction.redact/1` on every string value
  (recursively for structured events), so a secret shape in the harness stream
  is scrubbed on disk exactly like the prompt and context-store paths (T35.3).

  ## Size cap

  `tee/3` accepts a `:cap_bytes` option (default 10 MiB, `default_cap_bytes/0`).
  Once the sink's on-disk size would exceed the cap, remaining events
  in this call are DROPPED — but a single explicit `%{"type" => "truncated"}`
  marker event is appended so a reader can tell "the transcript stopped here on
  purpose" from a torn/crashed write. The marker is written at most once per
  sink file (checked before appending), so a truncated sink stays truncated
  across every subsequent iteration's tee call rather than accumulating one
  marker per iteration.
  """

  require Logger

  alias Kazi.Redaction

  @default_cap_bytes 10 * 1024 * 1024

  @doc "The default size cap (bytes) applied when `tee/3` receives no `:cap_bytes` opt."
  @spec default_cap_bytes() :: pos_integer()
  def default_cap_bytes, do: @default_cap_bytes

  @doc """
  Reads `path` back into a list of decoded event maps, oldest first — the same
  contract as `Kazi.Sink.Events.read/1`. A torn final line (a process killed
  mid-write) is silently dropped rather than raising; every earlier line is
  still returned. A missing file reads as an empty list. This is the reader a
  "transcript peek" view (T46.8) polls, and the one a post-mortem view reads
  once for a finished/dead run's sink -- the same code path either way.
  """
  @spec read(String.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, decoded} -> [decoded]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Tees `raw_output` to `path` as redacted JSONL, appending to any existing
  content. `path` may be `nil` (no sink configured) — a no-op. Best-effort:
  any failure (an unwritable directory, a transient I/O error) is caught and
  logged, never raised into the dispatch path.
  """
  @spec tee(String.t() | nil, String.t(), keyword()) :: :ok
  def tee(path, raw_output, opts \\ [])

  def tee(nil, _raw_output, _opts), do: :ok
  def tee(_path, "", _opts), do: :ok

  def tee(path, raw_output, opts) when is_binary(path) and is_binary(raw_output) do
    cap_bytes = Keyword.get(opts, :cap_bytes, @default_cap_bytes)

    path
    |> Path.dirname()
    |> File.mkdir_p!()

    unless already_truncated?(path) do
      raw_output
      |> String.split("\n", trim: true)
      |> Enum.map(&to_event/1)
      |> append_within_cap(path, cap_bytes)
    end

    :ok
  rescue
    error ->
      Logger.warning(fn -> "kazi transcript sink tee failed for #{path}: #{inspect(error)}" end)
      :ok
  end

  # =============================================================================
  # Event extraction
  # =============================================================================

  defp to_event(line) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} -> redact_event(decoded)
      _ -> %{"type" => "text", "text" => Redaction.redact(line)}
    end
  end

  defp redact_event(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, redact_value(v)} end)
  end

  defp redact_value(v) when is_binary(v), do: Redaction.redact(v)
  defp redact_value(v) when is_map(v), do: redact_event(v)
  defp redact_value(v) when is_list(v), do: Enum.map(v, &redact_value/1)
  defp redact_value(v), do: v

  # =============================================================================
  # Capped, ordered append
  # =============================================================================

  defp append_within_cap(events, path, cap_bytes) do
    Enum.reduce_while(events, current_size(path), fn event, size ->
      line = encode(event)
      new_size = size + byte_size(line)

      if new_size > cap_bytes do
        append_line(path, encode(truncated_event()))
        {:halt, new_size}
      else
        append_line(path, line)
        {:cont, new_size}
      end
    end)
  end

  defp truncated_event, do: %{"type" => "truncated", "reason" => "size_cap_exceeded"}

  defp already_truncated?(path) do
    case File.read(path) do
      {:ok, content} -> String.contains?(content, ~s("type":"truncated"))
      {:error, _} -> false
    end
  end

  defp encode(event), do: Jason.encode!(event) <> "\n"

  defp append_line(path, line), do: File.write!(path, line, [:append])

  defp current_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _} -> 0
    end
  end
end
