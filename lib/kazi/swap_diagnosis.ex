defmodule Kazi.SwapDiagnosis do
  @moduledoc """
  Classifies a running-VM failure as "the installed release changed under us"
  (issue #856) rather than an ordinary application error, so a CLI entry point
  can print one clear line instead of a harness-profile stack trace plus
  Logger formatter-crash spam.

  A `kazi apply` binary can be upgraded in place (a new release tag lands on
  disk) while an old VM is still running against the previous release's beam
  files. The first time that VM lazily loads a module whose on-disk file no
  longer matches what it already has, the failure surfaces at whatever
  innocent call site triggered the load — in the reported case,
  `Kazi.Harness.Profiles.Claude.put_usage/2` — and the default Logger
  formatter can itself fail to render the report because ITS OWN modules are
  affected the same way. `:code.modified_modules/0` is the OTP-native signal
  for exactly this: every loaded module whose on-disk `.beam` file differs from
  what the VM has in memory, which is precisely what a binary swap looks like
  from inside the BEAM.
  """

  @diagnosis "installed release changed under a running VM -- re-run under the new binary"

  @doc "The one-line diagnosis message printed when a swap is detected."
  @spec message() :: String.t()
  def message, do: @diagnosis

  @doc """
  `true` when the running VM's loaded code no longer matches what is on disk —
  the signature of a binary swap happening underneath it. Accepts an injected
  `:modified_modules` list (the test seam) in `opts`; defaults to the real
  `:code.modified_modules/0`.
  """
  @spec release_swapped?(keyword()) :: boolean()
  def release_swapped?(opts \\ []) do
    modules = Keyword.get_lazy(opts, :modified_modules, &:code.modified_modules/0)
    match?([_ | _], modules)
  end

  @doc """
  Classifies a rescued error. Returns `{:release_swap, message()}` when the
  VM's own code is stale on disk (regardless of the specific exception this
  particular caller happened to hit — see moduledoc), or `:unclassified` so the
  caller re-raises/reports the original error unchanged.
  """
  @spec classify(Exception.t() | term(), keyword()) :: {:release_swap, String.t()} | :unclassified
  def classify(_error, opts \\ []) do
    if release_swapped?(opts) do
      {:release_swap, @diagnosis}
    else
      :unclassified
    end
  end

  @doc """
  Runs `fun`, catching any raised exception. A classified swap prints
  `message/0` to stderr and returns `1` instead of letting the exception (and
  a possibly-affected Logger formatter) crash further; an unclassified
  exception is re-raised unchanged — this never swallows a real bug.

  Shared by every CLI entry point (`Kazi.CLI.main/1`, `Kazi.Release.cli/1`,
  `Kazi.Release.burrito_main/0`) so all of them degrade the same way.
  """
  @spec guard((-> exit_code), keyword()) :: exit_code when exit_code: non_neg_integer()
  def guard(fun, opts \\ []) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      case classify(error, opts) do
        {:release_swap, message} ->
          IO.puts(:stderr, message)
          1

        :unclassified ->
          reraise error, __STACKTRACE__
      end
  end
end
