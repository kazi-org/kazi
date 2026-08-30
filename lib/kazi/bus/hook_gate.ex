defmodule Kazi.Bus.HookGate do
  @moduledoc """
  The opt-in gate `kazi bus hook <event>` (`Kazi.Bus.Hook.run/2`) checks
  BEFORE doing any work (ADR-0084, issue #1705, founder ruling 2026-08-30).

  ADR-0077 decision 4 treated *installing the Claude Code plugin* as the
  opt-in for the bundled session-bus hooks -- reasonable when the plugin was
  the exception, but the plugin also bundles the kazi skill and the kazi MCP
  server, which an operator legitimately wants WITHOUT the bus hooks (the
  fleet's coordination mechanism can be retired while the skill/MCP stay
  useful). A plugin install unconditionally wires `SessionStart` /
  `UserPromptSubmit` / `Notification` to `kazi bus hook <event>` with no
  further consent step, so every session on a machine that installed the
  plugin for the skill alone still pays a live daemon's full board/digest
  injection (measured 13.6 KB / ~3.4k tokens at one SessionStart) whether or
  not the bus is actually read. ADR-0084 narrows decision 4: plugin install
  is no longer BY ITSELF sufficient consent for the bus hooks specifically --
  they now need one more explicit, separate signal, defaulting OFF.

  Two independent ways to give that signal, checked in order:

    1. The `KAZI_BUS_HOOKS` environment variable, set to `"1"` or `"true"`.
       Cheapest for a fleet: exported once in a shell profile / launch
       agent's environment, covers every session on that machine.
    2. A marker file at `marker_path/1` (default
       `~/.config/kazi/bus-hooks-enabled`) -- for an operator who wants the
       opt-in to persist without touching shell config. `kazi install-hooks`
       (the CLI's own explicit-command consent channel, ADR-0071) writes this
       marker automatically on a successful install and removes it on a
       successful `--uninstall`: running that command IS already an explicit
       opt-in, so it continues to "just work" without a second manual step.
       An operator who only installed the Claude Code PLUGIN (no
       `install-hooks` run) gets neither the env var nor the marker, so the
       hooks stay silent until they opt in explicitly by either mechanism.

  Any raise/throw while probing either signal degrades to `false` -- a gate
  must never turn a hook into a crashing one.
  """

  # `KAZI_BUS_HOOKS=1` (or `=true`) is the fleet-wide, zero-file opt-in.
  @env_var "KAZI_BUS_HOOKS"
  @env_truthy ["1", "true"]

  # The default marker path (tilde-expanded). Deliberately OUTSIDE
  # `~/.claude` -- it gates a kazi-owned command, not a harness setting, and
  # must survive a harness settings wipe / reinstall untouched.
  @default_marker_path Path.join(["~", ".config", "kazi", "bus-hooks-enabled"])

  @doc """
  Whether the bus hooks are opted in for this invocation.

  Opts:

    * `:bus_hooks_enabled` -- an explicit boolean override (test seam, and the
      one a caller can set to bypass env/marker probing entirely). Wins
      outright when present.
    * `:getenv` -- `(String.t() -> String.t() | nil)`, defaults to
      `System.get_env/1`. Test seam so a test never depends on the real
      process environment.
    * `:marker_path` -- overrides `marker_path/1`'s default (tests point this
      at a tmp file so the real `~/.config/kazi` is never touched).

  Never raises: any error probing either signal degrades to `false`.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    case Keyword.get(opts, :bus_hooks_enabled) do
      explicit when is_boolean(explicit) -> explicit
      _absent -> env_enabled?(opts) or marker_present?(opts)
    end
  end

  @doc """
  The marker file path this gate checks (`opts[:marker_path]`, else the
  default `~/.config/kazi/bus-hooks-enabled`, tilde-expanded).
  """
  @spec marker_path(keyword()) :: Path.t()
  def marker_path(opts \\ []) do
    case Keyword.get(opts, :marker_path) do
      path when is_binary(path) -> Path.expand(path)
      _absent -> Path.expand(@default_marker_path)
    end
  end

  @doc """
  Writes the marker file (creating parent directories), opting the bus hooks
  in. `kazi install-hooks` calls this on a successful install -- running
  that explicit command already IS consent (ADR-0071), so the hooks it
  registers work without a second manual step. Best-effort: a write failure
  is reported but never raises, matching the hook contract's fail-silent
  posture (a gate that can crash a hook install is worse than a gate that
  occasionally under-enables).
  """
  @spec enable(keyword()) :: :ok | {:error, term()}
  def enable(opts \\ []) do
    path = marker_path(opts)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(
             path,
             "written by `kazi install-hooks` -- opts the session-bus hooks in (ADR-0084).\n" <>
               "delete this file, or run `kazi install-hooks --uninstall`, to opt back out.\n"
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes the marker file (opting back out). `kazi install-hooks --uninstall`
  calls this after it actually removes the hook registrations. Idempotent --
  a missing marker is `:ok`, not an error -- and best-effort: any other
  removal failure is swallowed rather than raised, mirroring `enable/1`.
  """
  @spec disable(keyword()) :: :ok
  def disable(opts \\ []) do
    case File.rm(marker_path(opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # signal probes -- each degrades to false/not-present on any error
  # ---------------------------------------------------------------------------

  defp env_enabled?(opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    getenv.(@env_var) in @env_truthy
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp marker_present?(opts) do
    File.exists?(marker_path(opts))
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end
end
