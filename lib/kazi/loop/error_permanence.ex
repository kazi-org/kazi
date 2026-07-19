defmodule Kazi.Loop.ErrorPermanence do
  @moduledoc """
  The error-permanence taxonomy for `Kazi.PredicateResult` `:error` reasons
  (T48.2, UC-064, ADR-0058).

  A bare `:error` status conflates two very different situations (ADR-0058
  §Context): a config problem that will **never** resolve without a human or
  goal-file change (a live predicate missing its required `:url`, a predicate
  kind with no registered provider), and a genuine infra hiccup that MAY clear
  on its own (a request timeout, a connection refused, a checker script that
  exited non-zero this once). Today both are the SAME bare `:error`, so the
  loop's persistent-error detection (`Kazi.Loop.StuckDetector.error_stuck?/2`)
  can only say "still erroring", never "still erroring, and this can never
  pass" — the difference the operator actually needs (ADR-0058 §Decision,
  budget honesty).

  This module is that missing distinction, factored out pure so it is testable
  in complete isolation from the loop:

    * `:permanent` — the error can never clear without a **human or config
      change**. Every real-world case observed so far is a goal-file/predicate
      declaration problem: a required key is absent (`:missing_url`,
      `:missing_cmd`), the predicate kind has no provider or is unsupported by
      the one it got (`:no_provider`, `:unsupported_kind`), or the declared
      command/config is malformed (`:invalid_cmd`, `:unknown_verdict`,
      `:cmd_unrunnable` — binary missing or bad cwd, `:invalid_config`).
      Retrying changes nothing; polling it forever just burns budget on a
      config error the loop could have named on the FIRST observation.
    * `:transient` — the error may clear on its own: a timeout, a connection
      failure, or a checker that exited non-zero / produced unparseable output
      this one time (`:timeout_ms`, `:error_exit`, `:tool_unrunnable`,
      `:runner_failed`, `:query_failed`, `:invalid_runner_result`,
      `:unparseable_runner_output`, and any string reason — the live HTTP
      providers report `:httpc`/socket errors as inspected strings, e.g.
      `"econnrefused"`).
    * **Unknown reasons default `:transient`.** A provider this module has
      never seen is treated as "might still recover" rather than silently
      declared unrecoverable — the safer failure mode is one extra poll cycle,
      never a false-permanent stop on a reason nobody classified yet.

  This module makes NO decision about what the loop does with the verdict (that
  is T48.3, wiring `classify_result/1`/`classify/1` into the loop's live-predicate
  persistent-error check) and performs no I/O — it is a pure lookup over the
  reason term a provider already put in `PredicateResult.evidence[:reason]`
  (see `Kazi.Providers.HttpProbe`, `Kazi.Providers.CustomScript`, and the other
  `Kazi.Providers.*` modules for where these reasons originate).

  ## Survey (T48.2)

  The reasons classified here are every REAL reason atom/tuple found across
  `lib/kazi/providers/*.ex` and `Kazi.Loop`'s own `:no_provider` path at the
  time of writing — not a speculative list. A provider that starts emitting a
  new reason is safe by default (falls to `:transient`) until this module is
  deliberately extended to name it `:permanent`.
  """

  alias Kazi.PredicateResult

  @typedoc """
  Whether an `:error` reason can ever clear without external intervention.

    * `:permanent` — a config/wiring problem; will not clear on retry.
    * `:transient` — an infra hiccup; may clear on retry.
  """
  @type permanence :: :permanent | :transient

  # Bare-atom reasons that are, by construction, missing-required-config or
  # goal/provider wiring problems (ADR-0058 §Decision, "missing required
  # config"). None of these can pass by re-observing; they need a goal-file or
  # environment change.
  @permanent_atoms MapSet.new([
                     # Kazi.Providers.HttpProbe: no `:url` configured.
                     :missing_url,
                     # Kazi.Providers.CustomScript: no `:cmd` configured.
                     :missing_cmd,
                     # Kazi.Loop.run_provider/3: predicate kind has no
                     # registered provider at all.
                     :no_provider,
                     # Kazi.Providers.HttpProbe's bare-atom variant (the other
                     # providers emit the {:unsupported_kind, kind} tuple below).
                     :unsupported_kind
                   ])

  # Tuple reasons `{tag, _}` whose TAG marks a permanent (config/wiring)
  # problem, regardless of the tuple's other element(s).
  @permanent_tuple_tags MapSet.new([
                          # Every non-http_probe provider's kind-mismatch reason.
                          :unsupported_kind,
                          # Kazi.Providers.CustomScript: declared :cmd is not a
                          # non-empty string.
                          :invalid_cmd,
                          # Kazi.Providers.CustomScript: declared :verdict is not
                          # one of the recognised values.
                          :unknown_verdict,
                          # Kazi.Providers.CommandRunner's {:raised, message}
                          # path, re-tagged by every command-running provider:
                          # the binary does not exist or the cwd is invalid —
                          # nothing about a retry changes that.
                          :cmd_unrunnable,
                          # Kazi.Providers.Browser: the runner payload itself
                          # could not be encoded (malformed predicate config).
                          :invalid_config
                        ])

  @doc """
  Classifies an `:error` reason term as `:permanent` or `:transient`.

  Accepts whatever a provider put in `evidence[:reason]` — a bare atom, a
  `{tag, detail}` tuple, a string (the live HTTP providers inspect `:httpc`
  connection errors to strings), or anything else. A reason this module does
  not recognise defaults `:transient` (see moduledoc) — it never guesses
  `:permanent` on an unfamiliar shape.

  ## Examples

      iex> Kazi.Loop.ErrorPermanence.classify(:missing_url)
      :permanent

      iex> Kazi.Loop.ErrorPermanence.classify(:no_provider)
      :permanent

      iex> Kazi.Loop.ErrorPermanence.classify({:unsupported_kind, :bogus})
      :permanent

      iex> Kazi.Loop.ErrorPermanence.classify({:cmd_unrunnable, "enoent"})
      :permanent

      iex> Kazi.Loop.ErrorPermanence.classify({:timeout_ms, 5_000})
      :transient

      iex> Kazi.Loop.ErrorPermanence.classify({:error_exit, 1})
      :transient

      iex> Kazi.Loop.ErrorPermanence.classify("econnrefused")
      :transient

      iex> Kazi.Loop.ErrorPermanence.classify(:a_reason_nobody_has_seen_before)
      :transient
  """
  @spec classify(term()) :: permanence()
  def classify(reason) when is_atom(reason) and reason != nil do
    if MapSet.member?(@permanent_atoms, reason), do: :permanent, else: :transient
  end

  def classify(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    tag = elem(reason, 0)
    if MapSet.member?(@permanent_tuple_tags, tag), do: :permanent, else: :transient
  end

  def classify(_reason), do: :transient

  @doc """
  True iff `reason` classifies `:permanent` (see `classify/1`).

  ## Examples

      iex> Kazi.Loop.ErrorPermanence.permanent?(:missing_url)
      true

      iex> Kazi.Loop.ErrorPermanence.permanent?({:timeout_ms, 100})
      false
  """
  @spec permanent?(term()) :: boolean()
  def permanent?(reason), do: classify(reason) == :permanent

  @doc """
  True iff `reason` classifies `:transient` (see `classify/1`).

  ## Examples

      iex> Kazi.Loop.ErrorPermanence.transient?({:timeout_ms, 100})
      true

      iex> Kazi.Loop.ErrorPermanence.transient?(:missing_url)
      false
  """
  @spec transient?(term()) :: boolean()
  def transient?(reason), do: classify(reason) == :transient

  @doc """
  Classifies a `Kazi.PredicateResult` directly, reading `evidence[:reason]`.

  A result with no `:reason` key (a provider that emitted a bare `:error` with
  no reason evidence at all) defaults `:transient`, matching `classify/1`'s
  unknown-reason default — absence of a reason is not evidence of permanence.
  This does not check `result.status`; callers pass it an `:error` result (the
  only status the reason taxonomy is meaningful for).

  ## Examples

      iex> r = Kazi.PredicateResult.error(%{reason: :missing_url})
      iex> Kazi.Loop.ErrorPermanence.classify_result(r)
      :permanent

      iex> r = Kazi.PredicateResult.error(%{reason: {:timeout_ms, 100}})
      iex> Kazi.Loop.ErrorPermanence.classify_result(r)
      :transient

      iex> Kazi.Loop.ErrorPermanence.classify_result(Kazi.PredicateResult.error())
      :transient
  """
  @spec classify_result(PredicateResult.t()) :: permanence()
  def classify_result(%PredicateResult{evidence: evidence}) do
    classify(Map.get(evidence, :reason))
  end
end
