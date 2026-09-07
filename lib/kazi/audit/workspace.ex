defmodule Kazi.Audit.Workspace do
  @moduledoc "Runs a declared fault in a disposable candidate worktree using real providers."
  alias Kazi.{Goal, Runtime, Seal}
  alias Kazi.Audit.PredicateSensitivity
  alias Kazi.Providers.CommandRunner

  @doc "Audits a frozen goal against candidate_ref and fault_patch; never edits the caller tree."
  def run(repo, candidate_ref, %Goal{} = verifier, targets, fault_patch, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    root = Path.join(System.tmp_dir!(), "kazi-audit-#{Ecto.UUID.generate()}")
    work = Path.join(root, "candidate")
    File.mkdir_p!(root)
    patch = Path.join(root, "fault.patch")
    File.write!(patch, fault_patch)

    result =
      try do
        with {:ok, sha} <-
               git(repo, ["rev-parse", "--verify", "#{candidate_ref}^{commit}"], timeout),
             {:ok, _} <-
               git(repo, ["worktree", "add", "--detach", work, String.trim(sha)], timeout) do
          # Freeze checker inputs at the candidate before applying the fault.
          manifest = Seal.arm(verifier.seal, nil, work)

          with true <- map_size(manifest) > 0,
               true <- Enum.all?(Goal.all_predicates(verifier), &(&1.kind == :custom_script)),
               {:ok, baseline} <- check(verifier, work, root, timeout),
               %{eligible: _} <-
                 PredicateSensitivity.score(baseline.vector, baseline.vector, targets),
               true <- baseline.status == :pass,
               {:ok, _} <- git(work, ["apply", "--check", patch], timeout),
               {:ok, _} <- git(work, ["apply", patch], timeout),
               :ok <- Seal.verify(manifest),
               {:ok, mutated} <- check(%{verifier | setup: nil}, work, root, timeout),
               :ok <- Seal.verify(manifest) do
            {:ok,
             PredicateSensitivity.score(baseline.vector, mutated.vector, targets)
             |> Map.put(:candidate_ref, String.trim(sha))
             |> Map.put(
               :fault_fingerprint,
               Base.encode16(:crypto.hash(:sha256, fault_patch), case: :lower)
             )}
          else
            reason -> {:inconclusive, %{reason: reason, targets: targets}}
          end
        else
          reason -> {:inconclusive, %{reason: reason, targets: targets}}
        end
      rescue
        error -> {:inconclusive, %{reason: Exception.message(error), targets: targets}}
      after
        for path <- Path.wildcard(Path.join(root, "*.pid")) do
          case File.read(path) do
            {:ok, pid} -> Kazi.Harness.ChildSupervisor.reap(String.trim(pid))
            _ -> :ok
          end
        end
      end

    cleanup =
      if File.dir?(work),
        do: git(repo, ["worktree", "remove", "--force", work], max(timeout, 5_000)),
        else: {:ok, ""}

    case cleanup do
      {:ok, _} ->
        File.rm_rf!(root)
        result

      error ->
        {:inconclusive, %{reason: {:cleanup_failed, error}, workspace: work, targets: targets}}
    end
  end

  defp check(goal, work, root, timeout) do
    wrap = fn p ->
      config = p.config
      cmd = config[:cmd]

      cmd =
        if is_binary(cmd) and File.regular?(Path.join(work, cmd)),
          do: Path.join(work, cmd),
          else: cmd

      pid_file = Path.join(root, "#{Ecto.UUID.generate()}.pid")

      if is_binary(cmd) do
        {cmd, args} =
          Kazi.Harness.ChildSupervisor.wrap(cmd, config[:args] || [], pid_file: pid_file)

        %{p | config: config |> Map.put(:cmd, cmd) |> Map.put(:args, args)}
      else
        p
      end
    end

    goal = %{
      goal
      | predicates: Enum.map(goal.predicates, wrap),
        guards: Enum.map(goal.guards, wrap)
    }

    task =
      Task.async(fn ->
        try do
          Runtime.check(goal, workspace: work)
        rescue
          error -> {:error, {:checker_error, Exception.message(error)}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :checker_timeout}
    end
  end

  defp git(repo, args, timeout) do
    case CommandRunner.run("git", args, [cd: repo, stderr_to_stdout: true], timeout) do
      {:ran, output, 0} -> {:ok, output}
      other -> {:error, other}
    end
  end
end
