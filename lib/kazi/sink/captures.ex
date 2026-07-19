defmodule Kazi.Sink.Captures do
  @moduledoc """
  The per-run **evidence store** and controller-side executor for capture recipes
  (ADR-0081, #1521).

  A capture recipe (`Kazi.Capture`) is a command the CONTROLLER runs each observe
  pass to produce a visual artifact a predicate consumes as evidence. This module
  is where that happens: it executes each recipe via the injectable
  `Kazi.Providers.CommandRunner` seam and retains the artifact + a provenance
  sidecar under the run-keyed store

      <sinks_dir>/<run_id>/captures/<iteration>/<name>/<output>
      <sinks_dir>/<run_id>/captures/<iteration>/<name>/capture.json

  which lives OUTSIDE the workspace the worker edits — that separation IS the
  write-protection (ADR-0081 §3). Named distinctly from the unrelated per-finding
  `Kazi.Evidence` diagnostic type (ADR-0041).

  ## The recipe→artifact contract

  A recipe declares an `output` FILENAME, not a path. The executor resolves it to
  the absolute store destination and hands it to the recipe through two
  environment variables, running the recipe with the WORKSPACE as cwd (so
  workspace-relative scripts and builds resolve) while the artifact lands in
  controller space:

    * `KAZI_CAPTURE_OUTPUT` — the absolute file the recipe must write.
    * `KAZI_CAPTURE_DIR` — the recipe's per-capture store directory.

  The recipe is responsible for writing its artifact to `KAZI_CAPTURE_OUTPUT`. The
  executor then reads it back, hashes it, and records the provenance — it never
  trusts a workspace path the recipe (or the worker) chose.

  ## Capture result

  `run/2` returns `%{name => result}` where each `result` is a plain map:

      %{name:, ok:, exit:, artifact_path:, bytes:, sha256:, ran_at:, reason:}

  `ok` is true only when the launch command exited 0 AND a non-empty artifact
  landed at the destination. A failed reset, a launch that could not run
  (`:raised`), a timeout, a non-zero exit, or a missing artifact all yield
  `ok: false` with a `reason` — never a raised error into the loop.
  """

  alias Kazi.Providers.CommandRunner

  @provenance_file "capture.json"

  @typedoc "One capture's outcome (the map threaded into `context[:captures]`)."
  @type result :: %{
          name: String.t(),
          ok: boolean(),
          exit: integer() | nil,
          artifact_path: String.t() | nil,
          bytes: non_neg_integer() | nil,
          sha256: String.t() | nil,
          ran_at: String.t(),
          reason: atom() | nil
        }

  @doc """
  The run-keyed store directory for one observe iteration:
  `<sinks_dir>/<run_id>/captures/<iteration>`. Absolute-joined so callers can
  reason about workspace-externality.
  """
  @spec iteration_dir(String.t(), String.t(), non_neg_integer()) :: String.t()
  def iteration_dir(sinks_dir, run_id, iteration)
      when is_binary(sinks_dir) and is_binary(run_id) do
    Path.join([sinks_dir, run_id, "captures", Integer.to_string(iteration)])
  end

  @doc """
  Executes every recipe in `captures` for one observe pass, writing artifacts +
  provenance into `opts[:dir]` (the `iteration_dir/3` above), and returns
  `%{name => result}`.

  Options:

    * `:dir` — required; the controller-owned iteration store directory.
    * `:workspace` — the cwd recipes run in (defaults to the current dir).
    * `:runner` — the injectable command runner (default
      `&Kazi.Providers.CommandRunner.run/4`); tests may substitute a stub.

  A non-list / empty `captures` is a no-op returning `%{}`.
  """
  @spec run([Kazi.Capture.t()], keyword()) :: %{optional(String.t()) => result()}
  def run([], _opts), do: %{}

  def run(captures, opts) when is_list(captures) do
    dir = Keyword.fetch!(opts, :dir)
    workspace = Keyword.get(opts, :workspace) || File.cwd!()
    runner = Keyword.get(opts, :runner, &CommandRunner.run/4)

    Map.new(captures, fn %Kazi.Capture{} = capture ->
      {capture.name, run_one(capture, dir, workspace, runner)}
    end)
  end

  defp run_one(%Kazi.Capture{} = capture, dir, workspace, runner) do
    capture_dir = Path.join(dir, capture.name)
    File.mkdir_p!(capture_dir)
    dest = Path.join(capture_dir, capture.output)
    env = [{"KAZI_CAPTURE_OUTPUT", dest}, {"KAZI_CAPTURE_DIR", capture_dir}]
    ran_at = DateTime.utc_now() |> DateTime.to_iso8601()

    result =
      with :ok <- maybe_reset(capture, workspace, env, runner),
           {:ok, exit} <- launch(capture, workspace, env, runner) do
        maybe_wait(capture)
        read_artifact(capture.name, dest, exit, ran_at)
      else
        {:error, reason, exit} -> failure(capture.name, dest, exit, ran_at, reason)
      end

    write_provenance(capture, capture_dir, result)
    result
  end

  # The optional fresh-environment reset (ADR-0081 §1). A reset that cannot run or
  # exits non-zero fails the whole capture (a stale environment must not silently
  # answer for current code).
  defp maybe_reset(%Kazi.Capture{reset_cmd: nil}, _ws, _env, _runner), do: :ok

  defp maybe_reset(%Kazi.Capture{reset_cmd: cmd} = capture, workspace, env, runner) do
    case runner.(
           cmd,
           capture.reset_args,
           [cd: workspace, env: env, stderr_to_stdout: true],
           capture.timeout_ms
         ) do
      {:ran, _out, 0} -> :ok
      {:ran, _out, exit} -> {:error, :reset_failed, exit}
      {:raised, _msg} -> {:error, :reset_unavailable, nil}
      {:timeout, _ms} -> {:error, :reset_timeout, nil}
    end
  end

  defp launch(%Kazi.Capture{launch_cmd: cmd} = capture, workspace, env, runner) do
    case runner.(
           cmd,
           capture.launch_args,
           [cd: workspace, env: env, stderr_to_stdout: true],
           capture.timeout_ms
         ) do
      {:ran, _out, exit} -> {:ok, exit}
      {:raised, _msg} -> {:error, :launch_unavailable, nil}
      {:timeout, _ms} -> {:error, :launch_timeout, nil}
    end
  end

  defp maybe_wait(%Kazi.Capture{post_launch_wait_ms: ms, timeout_ms: cap}) when ms > 0 do
    Process.sleep(min(ms, cap))
  end

  defp maybe_wait(_capture), do: :ok

  # Read the artifact the recipe was told to write. A present, non-empty file with
  # a zero exit is a successful capture; anything else is `ok: false` with a
  # reason a consuming predicate reads as failing work (never raised into the loop).
  defp read_artifact(name, dest, exit, ran_at) do
    case File.read(dest) do
      {:ok, bytes} when byte_size(bytes) > 0 and exit == 0 ->
        %{
          name: name,
          ok: true,
          exit: exit,
          artifact_path: dest,
          bytes: byte_size(bytes),
          sha256: sha256_hex(bytes),
          ran_at: ran_at,
          reason: nil
        }

      {:ok, bytes} ->
        base = failure(name, dest, exit, ran_at, reason_for(exit, bytes))
        %{base | bytes: byte_size(bytes), sha256: sha256_hex(bytes), artifact_path: dest}

      {:error, _} ->
        failure(name, dest, exit, ran_at, :no_artifact)
    end
  end

  defp reason_for(exit, _bytes) when exit != 0, do: :nonzero_exit
  defp reason_for(_exit, bytes) when byte_size(bytes) == 0, do: :empty_artifact
  defp reason_for(_exit, _bytes), do: :no_artifact

  defp failure(name, dest, exit, ran_at, reason) do
    %{
      name: name,
      ok: false,
      exit: exit,
      artifact_path: if(File.regular?(dest), do: dest, else: nil),
      bytes: nil,
      sha256: nil,
      ran_at: ran_at,
      reason: reason
    }
  end

  # The provenance sidecar (ADR-0081 §3): who produced which bytes. Records the
  # recipe's command lines, exit, artifact hash + size, and timestamp — never the
  # artifact bytes inline (leak hygiene, ADR-0034). Best-effort: a write failure
  # never fails the capture.
  defp write_provenance(%Kazi.Capture{} = capture, capture_dir, result) do
    payload = %{
      name: capture.name,
      reset: command_line(capture.reset_cmd, capture.reset_args),
      launch: command_line(capture.launch_cmd, capture.launch_args),
      output: capture.output,
      ok: result.ok,
      exit: result.exit,
      bytes: result.bytes,
      sha256: result.sha256,
      reason: result.reason && Atom.to_string(result.reason),
      ran_at: result.ran_at
    }

    File.write(Path.join(capture_dir, @provenance_file), Jason.encode!(payload))
  rescue
    _ -> :ok
  end

  defp command_line(nil, _args), do: nil
  defp command_line(cmd, args), do: Enum.join([cmd | args], " ")

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
