defmodule Kazi.Setup do
  @moduledoc """
  A goal's declared provisioning step (issue #1642, ADR-0088): commands the
  controller runs ONCE, in the goal's workspace, BEFORE the t0 predicate
  observation — so a build-tool-backed predicate (`mix test`, `mix format
  --check-formatted`, `npm test`, ...) is never red for an ENVIRONMENTAL reason.

  A `kazi apply` task worktree is created via `git worktree add`; nothing in
  that path runs `mix deps.get` (or any language-appropriate equivalent), so
  every build-tool-backed predicate fails at t0 with "Unchecked dependencies"
  regardless of the goal's real state — defeating the "red-at-t0 proves the
  predicate measures real behavior" guarantee (concept R3,
  `Kazi.Runtime`'s vacuous-goal guard). `[setup]` closes that gap the same way
  ADR-0035/ADR-0056 already settled the question for model-tiering policy:
  goal-file DATA, never kazi-core auto-detection. Auto-detecting the build tool
  and "the harness provisions implicitly" were both considered and explicitly
  rejected on issue #1642 — a detector is one more thing to keep in sync with
  every ecosystem's conventions, and "the harness does it" is unfalsifiable and
  differs per harness/model. kazi runs exactly what a goal DECLARES.

  ## Fields

    * `commands` — a list of shell command strings run IN ORDER, each through
      `sh -c`, in the goal's workspace. Absent/empty (`[]`, the default) means
      no setup step — byte-identical to before this feature existed.
    * `timeout_ms` — the per-command hard deadline, ALWAYS a positive integer
      (default `#{inspect(300_000)}`). Issue #1642's whole point is closing an
      environmental startup-wedge class, so a setup command can never wait
      forever any more than the t0 predicate observation can (the #1683/T69.2
      treatment `Kazi.Runtime` already applies to `observe_t0/3`) — there is
      deliberately no way to author an unbounded `[setup]` command.

  ## Failure is a distinct environment error, never a predicate verdict

  A setup command that exits non-zero, cannot be started (missing binary, bad
  workspace), or overruns its timeout STOPS the run before the t0 observation
  and is reported as `{:error, {:setup_failed, failure}}` — never a predicate
  `:fail`. This mirrors `Kazi.Runtime`'s existing `{:error,
  {:startup_deadline_exceeded, ms}}` shape (issue #1683): both are named,
  structured INFRASTRUCTURE errors the caller renders distinctly from a
  predicate result, because a broken environment is not failing product work
  (ADR-0002's `:error` vs `:fail` boundary).
  """

  alias Kazi.Providers.CommandRunner

  @typedoc "Why one `[setup]` command did not succeed."
  @type failure_reason :: :exit_code | :raised | :timeout

  @typedoc "A named setup failure: which command, at what index, and why."
  @type failure :: %{
          command: String.t(),
          index: non_neg_integer(),
          reason: failure_reason(),
          detail: String.t()
        }

  @type t :: %__MODULE__{
          commands: [String.t()],
          timeout_ms: pos_integer()
        }

  @default_timeout_ms 300_000

  defstruct commands: [], timeout_ms: @default_timeout_ms

  @doc "The default per-command timeout (ms) applied when `[setup]` declares none."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Builds a setup step.

  ## Examples

      iex> Kazi.Setup.new(commands: ["mix deps.get"]).commands
      ["mix deps.get"]

      iex> Kazi.Setup.new().timeout_ms
      300_000
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      commands: Keyword.get(opts, :commands, []),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }
  end

  @doc """
  Runs every declared command, in order, in `workspace` — stopping at the
  FIRST failure. Returns `:ok` when every command exits `0` (or nothing is
  declared: `nil` or `commands: []` both no-op, so an absent `[setup]` block
  is byte-identical to before this feature existed), or
  `{:error, {:setup_failed, failure}}` naming the offending command.

  `opts[:command_runner]` overrides the command-execution seam — a
  `(cmd, args, cmd_opts, timeout_ms -> CommandRunner.result())` fun, the same
  contract as `Kazi.Providers.CommandRunner.run/4` (default) — so a hermetic
  test never has to shell out for real, mirroring `Kazi.Apply.Preflight`'s
  injectable seam convention.
  """
  @spec run(t() | nil, String.t(), keyword()) :: :ok | {:error, {:setup_failed, failure()}}
  def run(nil, _workspace, _opts), do: :ok
  def run(%__MODULE__{commands: []}, _workspace, _opts), do: :ok

  def run(%__MODULE__{commands: commands, timeout_ms: timeout_ms}, workspace, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/4)

    commands
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {command, index}, :ok ->
      cmd_opts = [cd: workspace, stderr_to_stdout: true]

      case runner.("sh", ["-c", command], cmd_opts, timeout_ms) do
        {:ran, _output, 0} ->
          {:cont, :ok}

        {:ran, output, exit_code} ->
          {:halt, halt(command, index, :exit_code, "exit #{exit_code}#{output_detail(output)}")}

        {:raised, message} ->
          {:halt, halt(command, index, :raised, message)}

        {:timeout, ms} ->
          {:halt, halt(command, index, :timeout, "timed out after #{ms}ms")}
      end
    end)
  end

  defp halt(command, index, reason, detail) do
    {:error, {:setup_failed, %{command: command, index: index, reason: reason, detail: detail}}}
  end

  # A bounded tail of command output — enough to diagnose a `mix deps.get`
  # network/registry failure without unbounded checker text landing in a
  # result term (and, downstream, in a persisted run record).
  @max_detail_chars 4000

  defp output_detail(output) do
    case String.trim(output) do
      "" ->
        ""

      trimmed ->
        if String.length(trimmed) > @max_detail_chars do
          " Output (truncated to the last #{@max_detail_chars} chars): " <>
            String.slice(trimmed, -@max_detail_chars..-1)
        else
          " Output: " <> trimmed
        end
    end
  end
end
