defmodule Kazi.Scheduler.Integration do
  @moduledoc """
  Collective **integration + merge convergence** across converged partitions
  (T21.5, ADR-0027 step 4): once each partition has CONVERGED in its own isolated
  worktree, integrate them — branch → PR → rebase-merge — in a SAFE ORDER,
  detect residual CROSS-PARTITION conflicts, and RE-DISPATCH the affected
  partition until the merged whole is green.

  ADR-0027 step 4 / concept §9: disjoint blast radii make cross-partition
  conflicts RARE by construction, but not impossible — a partition's edits can
  expand its radius mid-run and collide with a sibling that already merged. This
  module is the collective's "the parts converged; is the WHOLE green?" stage. A
  collective is `:converged` ONLY when every partition merged cleanly into the
  shared base; a partition that conflicts on merge is re-dispatched (rebased onto
  the new base and re-reconciled) and re-attempted, bounded by a retry budget.

  ## The injectable integrator seam (mirrors `Kazi.Runtime`)

  Exactly like `Kazi.Runtime` threads an `:integrator` / `:deploy_cmd` into the
  actions' own seams (so tests never touch `gh`/`gcloud`), this module isolates
  the remote-dependent merge behind an injectable **integrator** so the
  acceptance test uses a STUB — no real `git`/`gh`. The integrator is a function

      integrator :: (integration_request(), keyword() -> {:ok, map()} | {:error, term()})

  where the result map distinguishes a clean merge from a conflict: a `{:ok, map}`
  with `map.conflict` truthy (or an `{:error, {:conflict, _}}`) means the partition
  conflicted against the current base and must be re-dispatched. The DEFAULT
  integrator (`Kazi.Scheduler.Integration.ActionIntegrator`) is REAL — it drives
  `Kazi.Actions.Integrate` (which itself defaults to the `gh` CLI) — so production
  wiring injects nothing; only tests inject a stub.

  ## Safe order

  Partitions integrate ONE AT A TIME (the merge to the shared base is inherently
  serial — each merge moves the base the next rebases onto), in a DETERMINISTIC
  safe order (`order_fun`, default by lease `:key`) so the sequence is reproducible
  and a conflict is attributable to a specific pair. Concurrency was ACROSS the
  reconcile phase (each partition's loop ran in parallel under the
  `DynamicSupervisor`); integration is the serial join that follows.

  ## Re-dispatch on cross-partition conflict

  When a partition conflicts on merge, the affected partition is RE-DISPATCHED:
  its reconciler is invoked again (its worktree rebased onto the now-advanced
  base), then the merge is re-attempted. This repeats up to `:max_attempts`
  (default 3); a partition that still conflicts after the budget is exhausted is
  reported `:conflict` and the collective is NOT green. Re-dispatch reuses the
  SAME injectable reconciler seam the scheduler already drives, so it is hermetic
  in tests.

  ## Result

  `integrate/2` returns `{:ok, t:result/0}`:

    * `:collective` — `:converged` only when EVERY partition merged cleanly;
      otherwise `:stuck` (an unresolved cross-partition conflict means the merged
      whole is not green);
    * `:integrated` — `[{partition, merge_result}]` in the order they merged;
    * `:conflicts` — `[{partition, reason}]` partitions that could not be merged
      within the retry budget (empty on full success);
    * `:redispatched` — `[{partition, attempts}]` partitions re-dispatched at least
      once (observability for the "conflict → re-dispatch" path).
  """

  require Logger

  @default_max_attempts 3

  @typedoc """
  The request handed to the integrator seam to merge one partition into the shared
  base. Mirrors `Kazi.Actions.Integrate.remote_request/0` but partition-keyed so
  the integrator can attribute a conflict and the caller can re-dispatch.

    * `:partition` — the partition being integrated (its worktree already holds the
      converged change);
    * `:key` — the partition's stable lease key (its identity in the safe order);
    * `:worktree` — the path to the partition's converged worktree (where its
      branch lives), or `nil` when the run did not isolate worktrees;
    * `:base` — the shared base branch every partition rebase-merges onto;
    * `:already_merged` — the keys of partitions ALREADY merged onto the base this
      run (so a conflict-detecting integrator/stub knows the current base state).
  """
  @type integration_request :: %{
          partition: Kazi.Scheduler.partition(),
          key: String.t() | nil,
          worktree: Path.t() | nil,
          base: String.t(),
          already_merged: [String.t() | nil]
        }

  @typedoc """
  The integrator seam: merges one partition into the shared base. Returns
  `{:ok, refs}` on a clean rebase-merge (refs typically carry `:pr` /
  `:merge_commit`); signals a cross-partition conflict with `{:ok, %{conflict:
  true, ...}}` or `{:error, {:conflict, _reason}}`; any other `{:error, _}` is a
  hard integration failure (not retried).
  """
  @type integrator :: (integration_request(), keyword() -> {:ok, map()} | {:error, term()})

  @typedoc """
  The re-dispatch seam: re-reconcile a partition that conflicted on merge (rebase
  its worktree onto the advanced base and re-converge). Returns the partition's
  terminal status; only `:converged` makes the partition eligible for another
  merge attempt. Defaults to a no-op that simply re-attempts the merge (a stub
  reconciler in tests resolves the conflict).
  """
  @type redispatcher ::
          (Kazi.Scheduler.partition() -> Kazi.Scheduler.partition_status())

  @type result :: %{
          collective: :converged | :stuck,
          integrated: [{Kazi.Scheduler.partition(), map()}],
          conflicts: [{Kazi.Scheduler.partition(), term()}],
          redispatched: [{Kazi.Scheduler.partition(), pos_integer()}]
        }

  @doc """
  Integrates the CONVERGED partitions into the shared base, in a safe order,
  re-dispatching any that conflict cross-partition, and reports whether the merged
  WHOLE is green.

  `entries` is the list of converged partitions to integrate. Each entry is either
  a bare partition (a `Kazi.Scheduler.Partitioner` struct or any term the
  `:order_fun` / `:key_fun` understand) or a `{partition, worktree_path}` tuple
  carrying the partition's converged worktree (as produced by the worktree seam).

  Only `:converged` partitions should be passed — a partition that did not
  converge has nothing to integrate; the caller (the scheduler) filters first and
  the collective is already non-green in that case.

  ## Options

    * `:integrator` — the injectable `t:integrator/0` (default the REAL
      `ActionIntegrator` over `Kazi.Actions.Integrate`). Tests inject a stub.
    * `:redispatcher` — the injectable `t:redispatcher/0` invoked to re-reconcile a
      conflicting partition before re-merging (default a no-op `:converged`, i.e.
      "just re-attempt the merge"; the real scheduler injects the partition's
      reconciler).
    * `:base` — the shared base branch (default `"main"`).
    * `:max_attempts` — merge attempts per partition before giving up (default
      `3`). Each conflict consumes one attempt; re-dispatch happens between
      attempts.
    * `:order_fun` — projects a partition onto a sortable term for the safe order
      (default by the partition's lease `:key`, then a stable index).
    * `:integrator_opts` — opts forwarded to every integrator call.

  Returns `{:ok, t:result/0}`. The collective is `:converged` ONLY when every
  partition merged within its budget; any residual conflict ⇒ `:stuck`.
  """
  @spec integrate(
          [Kazi.Scheduler.partition() | {Kazi.Scheduler.partition(), Path.t()}],
          keyword()
        ) ::
          {:ok, result()}
  def integrate(entries, opts \\ []) when is_list(entries) and is_list(opts) do
    integrator = Keyword.get(opts, :integrator, &__MODULE__.ActionIntegrator.integrate/2)
    redispatcher = Keyword.get(opts, :redispatcher, fn _partition -> :converged end)
    base = Keyword.get(opts, :base, "main")
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    order_fun = Keyword.get(opts, :order_fun, &default_order_key/1)
    integrator_opts = Keyword.get(opts, :integrator_opts, [])

    normalized = Enum.map(entries, &normalize_entry/1)

    # Safe order: deterministic, index-stable so equal keys keep input order.
    ordered =
      normalized
      |> Enum.with_index()
      |> Enum.sort_by(fn {entry, idx} -> {order_fun.(entry.partition), idx} end)
      |> Enum.map(&elem(&1, 0))

    ctx = %{
      integrator: integrator,
      redispatcher: redispatcher,
      base: base,
      max_attempts: max_attempts,
      integrator_opts: integrator_opts
    }

    initial = %{integrated: [], conflicts: [], redispatched: [], merged_keys: []}

    final = Enum.reduce(ordered, initial, &integrate_one(&1, &2, ctx))

    {:ok,
     %{
       collective: collective(final),
       integrated: Enum.reverse(final.integrated),
       conflicts: Enum.reverse(final.conflicts),
       redispatched: Enum.reverse(final.redispatched)
     }}
  end

  # Integrate ONE partition into the (advancing) base, with conflict re-dispatch up
  # to the attempt budget. Accumulates into the running result.
  defp integrate_one(entry, acc, ctx) do
    case attempt_merge(entry, ctx, acc.merged_keys, 1) do
      {:merged, refs, attempts} ->
        acc
        |> Map.update!(:integrated, &[{entry.partition, refs} | &1])
        |> Map.update!(:merged_keys, &[entry.key | &1])
        |> record_redispatch(entry.partition, attempts)

      {:conflict, reason, attempts} ->
        acc
        |> Map.update!(:conflicts, &[{entry.partition, reason} | &1])
        |> record_redispatch(entry.partition, attempts)

      {:error, reason} ->
        Map.update!(acc, :conflicts, &[{entry.partition, reason} | &1])
    end
  end

  # Try to merge `entry` onto the current base. On a cross-partition conflict,
  # RE-DISPATCH the partition (re-reconcile onto the advanced base) and retry,
  # bounded by `max_attempts`. A hard (non-conflict) integrator error aborts this
  # partition without retry.
  defp attempt_merge(entry, ctx, merged_keys, attempt) do
    request = %{
      partition: entry.partition,
      key: entry.key,
      worktree: entry.worktree,
      base: ctx.base,
      already_merged: merged_keys
    }

    case call_integrator(ctx.integrator, request, ctx.integrator_opts) do
      {:ok, refs} ->
        if conflict_signaled?(refs) do
          redispatch_or_give_up(entry, ctx, merged_keys, attempt, {:conflict, refs})
        else
          {:merged, refs, attempt}
        end

      {:error, {:conflict, _} = reason} ->
        redispatch_or_give_up(entry, ctx, merged_keys, attempt, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Either re-dispatch + retry (budget remaining and re-dispatch re-converges) or
  # give up with :conflict.
  defp redispatch_or_give_up(entry, ctx, merged_keys, attempt, reason) do
    if attempt < ctx.max_attempts do
      Logger.info(fn ->
        "kazi.scheduler.integration cross-partition conflict on #{inspect(entry.key)} " <>
          "(attempt #{attempt}/#{ctx.max_attempts}); re-dispatching"
      end)

      case run_redispatch(ctx.redispatcher, entry.partition) do
        :converged ->
          attempt_merge(entry, ctx, merged_keys, attempt + 1)

        other ->
          # Re-dispatch did not re-converge — the conflict stands.
          {:conflict, {:redispatch_failed, other}, attempt}
      end
    else
      {:conflict, conflict_reason(reason), attempt}
    end
  end

  defp conflict_reason({:conflict, _} = reason), do: reason
  defp conflict_reason(other), do: {:conflict, other}

  # A `{:ok, refs}` whose refs flag a conflict means the partition conflicted on
  # merge (so the integrator can report a conflict without an error tuple).
  # `refs` is always a map here (call_integrator only returns `{:ok, refs}` when
  # `is_map(refs)`). A truthy `:conflict` key is the integrator's "this partition
  # conflicted on merge" signal.
  defp conflict_signaled?(refs), do: Map.get(refs, :conflict) == true

  defp call_integrator(integrator, request, opts) do
    case integrator.(request, opts) do
      {:ok, refs} when is_map(refs) -> {:ok, refs}
      {:error, _} = err -> err
      other -> {:error, {:bad_integrator_result, other}}
    end
  rescue
    e -> {:error, {:integrator_raised, Exception.message(e)}}
  end

  defp run_redispatch(redispatcher, partition) do
    redispatcher.(partition)
  rescue
    e ->
      Logger.warning(fn ->
        "kazi.scheduler.integration re-dispatch raised: #{Exception.message(e)}"
      end)

      {:error, {:redispatch_raised, Exception.message(e)}}
  end

  defp record_redispatch(acc, _partition, attempts) when attempts <= 1, do: acc

  defp record_redispatch(acc, partition, attempts) do
    Map.update!(acc, :redispatched, &[{partition, attempts} | &1])
  end

  # The merged whole is green ONLY when nothing conflicted: every passed partition
  # merged cleanly into the shared base.
  defp collective(%{conflicts: []}), do: :converged
  defp collective(_), do: :stuck

  # Normalize an entry to `%{partition, key, worktree}`. Accepts a bare partition
  # or a `{partition, worktree_path}` tuple.
  defp normalize_entry({partition, worktree}) when is_binary(worktree) do
    %{partition: partition, key: entry_key(partition), worktree: worktree}
  end

  defp normalize_entry(partition) do
    %{partition: partition, key: entry_key(partition), worktree: nil}
  end

  defp entry_key(%{key: key}) when is_binary(key), do: key
  defp entry_key(_partition), do: nil

  # Default safe-order key: by the partition's stable lease key (deterministic);
  # partitions with no key sort last but stay index-stable (see the with_index/sort
  # in integrate/2).
  defp default_order_key(%{key: key}) when is_binary(key), do: {0, key}
  defp default_order_key(_partition), do: {1, ""}

  defmodule ActionIntegrator do
    @moduledoc """
    The **real** default integrator: merges one partition into the shared base by
    driving `Kazi.Actions.Integrate` (which itself defaults to the `gh` CLI). This
    is production wiring, not a stub — the seam exists so tests can substitute a
    stub integrator, not because the default is fake (mirrors
    `Kazi.Actions.Integrate.GhIntegrator`).

    It runs the integrate action in the partition's converged worktree, mapping a
    merge conflict surfaced by the action into the conflict signal the collective
    re-dispatches on.
    """

    alias Kazi.Action
    alias Kazi.Actions.Integrate

    @doc """
    Integrates one partition by running the real integrate action in its worktree.

    Returns `{:ok, refs}` on a clean rebase-merge, or `{:error, {:conflict,
    reason}}` when the action reports a merge conflict (so the collective
    re-dispatches the partition). Any other action error propagates as-is.
    """
    @spec integrate(Kazi.Scheduler.Integration.integration_request(), keyword()) ::
            {:ok, map()} | {:error, term()}
    def integrate(%{worktree: worktree, base: base}, opts) when is_binary(worktree) do
      action =
        Action.new(:integrate,
          params:
            %{base: base, workspace: worktree}
            |> Map.merge(Keyword.get(opts, :integrate_params, %{}))
        )

      context = Map.new(Keyword.get(opts, :integrate_context, []))

      case Integrate.execute(action, context) do
        {:ok, refs} -> {:ok, refs}
        {:error, reason} -> {:error, normalize_conflict(reason)}
      end
    end

    def integrate(%{worktree: nil}, _opts) do
      {:error, :no_worktree}
    end

    # Heuristic: map a push/merge failure that mentions a conflict into the
    # conflict signal the collective re-dispatches on. Anything else stays a hard
    # error.
    defp normalize_conflict({tag, output} = reason)
         when tag in [:push_failed, :pr_merge_failed] and is_binary(output) do
      if output =~ ~r/conflict/i, do: {:conflict, reason}, else: reason
    end

    defp normalize_conflict(reason), do: reason
  end
end
