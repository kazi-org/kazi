defmodule Kazi.Daemon.LaunchAgent do
  @moduledoc """
  The canonical service templates that keep the kazi bus daemon
  (`Kazi.Daemon`) running under an OS service manager — a macOS launchd
  **LaunchAgent** plist and a Linux **systemd** user unit (T66.6, #1579).

  ## Why explicit file-descriptor limits

  launchd starts a LaunchAgent with a SOFT open-files limit of **256** by
  default. Each `kazi bus who`/`join`/`daemon status` call opens a control-socket
  connection; under routine churn from a large `/apply --pool` fleet (~30
  concurrent sessions across machines sharing one bus) the daemon's accept loop
  exhausts 256 descriptors and every subsequent `:gen_tcp.accept` fails with
  `:emfile`:

      kazi daemon: accept failed: :emfile

  The daemon is then **alive but deaf** — the process is up, but it can no longer
  accept connections, so every CLI call times out. launchd's `KeepAlive` cannot
  recover this (the process never exits), so the only fix is to raise the limit
  before it is hit. These templates therefore ship EXPLICIT high
  `SoftResourceLimits`/`HardResourceLimits` → `NumberOfFiles` (launchd) and
  `LimitNOFILE` (systemd) so the emfile wedge cannot occur under a normal fleet.

  ## Why the job must be RE-REGISTERED after a binary upgrade (#1484)

  The installed binary is adhoc / linker-signed (`flags=0x20002(adhoc,
  linker-signed)`), so its code signature is bound to the exact bytes. When a
  package upgrade (Homebrew, a downloaded release, a self-update) replaces the
  binary in place UNDERNEATH a registered LaunchAgent, the job still pins a
  Lightweight Code Requirement against the PREVIOUS binary — `launchctl print`
  shows `needs LWCR update` — and launchd refuses to spawn it, reporting
  `last exit code = 78: EX_CONFIG`.

  78 is launchd's `EX_CONFIG`, NOT kazi's: kazi never returns it (running the
  job's own `ProgramArguments` by hand exits 1 with a real message). So the
  failure is invisible from inside the binary — it is never executed. The only
  remedy is to re-register the job (`launchctl bootout` + `bootstrap`, which
  re-pins the LWCR against the new bytes); a confirming experiment flipped the
  job's last exit code from 78 to 1 with the binary untouched. `reregister/0`
  names that remedy, `parse_job_state/1` + `stale_registration?/1` DETECT it
  from `launchctl print` output, and `kazi daemon reregister` performs it.

  ## Why `KeepAlive` is conditional (#1484 defect 2)

  A plain `KeepAlive: true` respawns forever, even against a PERMANENTLY failing
  precondition. The reporting machine reached **33,035** spawn attempts against a
  stale daemon that held the socket — a condition no amount of respawning can
  fix. The template therefore uses `KeepAlive: {SuccessfulExit: false}` (restart
  only when the run FAILED) and the templates export `KAZI_SUPERVISOR` so
  `kazi daemon start` knows it is running under a supervisor and can exit **0**
  on a permanent, operator-action condition — which stops the respawn loop
  instead of feeding it. A genuine crash still exits non-zero and is still
  restarted.

  This module only RENDERS the templates (pure, deterministic) and names the
  install path + reload/re-register commands; installing them is an operator step
  documented in `docs/session-bus.md`. Rendering is the shipped, greppable,
  test-pinned source of truth for the fd-limit and KeepAlive contracts.
  """

  @label "run.kazi.bushost"

  # Set by BOTH shipped templates (launchd `EnvironmentVariables`, systemd
  # `Environment=`) so a supervised `kazi daemon start` can tell it is being
  # respawned by a service manager. Deliberately an ENV VAR, not a CLI flag: an
  # env-var contract is inert for every hand-run invocation, and an operator's
  # existing plist keeps its own `ProgramArguments` untouched when re-rendered.
  #
  # NOT sniffable from launchd's own environment: a LaunchAgent job is spawned
  # with `XPC_SERVICE_NAME=0` (verified empirically — it carries the job Label
  # only for XPC service bundles), which is indistinguishable from an ordinary
  # GUI-session child. Hence an explicit variable kazi sets itself.
  @supervisor_env "KAZI_SUPERVISOR"

  # launchd's minimum spawn interval for the job. Explicit rather than implicit
  # (launchd's own default is also 10s) so the crashloop budget is greppable.
  @throttle_interval_s 10

  # Generous ceilings for a large multi-session fleet: comfortably above the
  # ~30-session churn that exhausted the launchd default of 256, well under the
  # macOS per-process hard cap. The daemon needs one fd per in-flight control
  # connection plus its listen socket, NATS connection, and read-model handles.
  @default_soft_nofiles 8192
  @default_hard_nofiles 16384

  @doc "The LaunchAgent / systemd service label."
  @spec label() :: String.t()
  def label, do: @label

  @doc "The default soft open-files limit the templates carry."
  @spec default_soft_nofiles() :: pos_integer()
  def default_soft_nofiles, do: @default_soft_nofiles

  @doc "The default hard open-files limit the templates carry."
  @spec default_hard_nofiles() :: pos_integer()
  def default_hard_nofiles, do: @default_hard_nofiles

  @doc "The conventional install path for the LaunchAgent plist."
  @spec plist_install_path() :: String.t()
  def plist_install_path do
    Path.join([System.user_home() || "~", "Library", "LaunchAgents", "#{@label}.plist"])
  end

  @doc "The environment variable both shipped templates set to name the supervisor."
  @spec supervisor_env_var() :: String.t()
  def supervisor_env_var, do: @supervisor_env

  @doc """
  The minimum interval (seconds) launchd/systemd waits between respawns.
  """
  @spec throttle_interval_s() :: pos_integer()
  def throttle_interval_s, do: @throttle_interval_s

  @doc """
  True when this process was spawned by one of the shipped service templates
  (launchd or systemd), read from `env` (defaults to the real environment).

  The ONLY signal is the `KAZI_SUPERVISOR` variable the templates set — launchd's
  own `XPC_SERVICE_NAME` is `0` for a LaunchAgent job and cannot be used.

  Callers use this to decide the exit code for a PERMANENT failure: under a
  supervisor, exiting non-zero merely feeds the restart loop (#1484).
  """
  @spec supervised?(map() | nil) :: boolean()
  def supervised?(env \\ nil) do
    env = env || System.get_env()
    Map.get(env, @supervisor_env) in ["launchd", "systemd"]
  end

  @doc "The supervisor name (`\"launchd\"` / `\"systemd\"`), or nil when unsupervised."
  @spec supervisor(map() | nil) :: String.t() | nil
  def supervisor(env \\ nil) do
    env = env || System.get_env()
    if supervised?(env), do: Map.get(env, @supervisor_env)
  end

  @doc """
  The `launchctl` command that force-restarts the agent — the operator remedy
  when the daemon is alive-but-deaf (emfile, wedged) and `KeepAlive` cannot
  recover it on its own.

  NOT the remedy for a stale REGISTRATION (`needs LWCR update` / exit 78): a
  kickstart re-runs the job under the same, still-invalid registration. That
  needs `reregister_command/0`.
  """
  @spec kickstart_command() :: String.t()
  def kickstart_command, do: "launchctl kickstart -k gui/$(id -u)/#{@label}"

  @doc """
  The `launchctl` incantation that RE-REGISTERS the agent — the remedy after the
  kazi binary has been replaced in place under a registered job (#1484). Bootout
  drops the job (and its stale Lightweight Code Requirement); bootstrap re-pins it
  against the current bytes.
  """
  @spec reregister_command() :: String.t()
  def reregister_command do
    "launchctl bootout gui/$(id -u)/#{@label} ; " <>
      "launchctl bootstrap gui/$(id -u) #{plist_install_path()}"
  end

  @doc """
  The re-register steps as executable argv, for a given numeric `uid` and plist
  path — pure, so the command construction is testable without touching launchd.

  Returns `[{"launchctl", args}, ...]` in order. The FIRST step (bootout) is
  allowed to fail: an unloaded job is a legitimate starting state.
  """
  @spec reregister_argv(String.t() | non_neg_integer(), String.t()) ::
          [{String.t(), [String.t()]}]
  def reregister_argv(uid, plist_path \\ nil) do
    plist_path = plist_path || plist_install_path()

    [
      {"launchctl", ["bootout", "gui/#{uid}/#{@label}"]},
      {"launchctl", ["bootstrap", "gui/#{uid}", plist_path]}
    ]
  end

  @doc """
  The `launchctl print` invocation whose output `parse_job_state/1` reads.
  """
  @spec print_argv(String.t() | non_neg_integer()) :: {String.t(), [String.t()]}
  def print_argv(uid), do: {"launchctl", ["print", "gui/#{uid}/#{@label}"]}

  @doc """
  Parses the fields of `launchctl print gui/<uid>/<label>` this module reasons
  about. Pure — the caller supplies the text, so every branch is testable on any
  OS without a registered job.

  Unparseable/absent fields come back `nil` (never guessed).
  """
  @spec parse_job_state(String.t()) :: %{
          runs: non_neg_integer() | nil,
          last_exit_code: integer() | nil,
          properties: [String.t()],
          needs_lwcr_update?: boolean()
        }
  def parse_job_state(text) when is_binary(text) do
    properties =
      case Regex.run(~r/^\s*properties\s*=\s*(.+)$/m, text) do
        [_, list] -> list |> String.split("|") |> Enum.map(&String.trim/1)
        _ -> []
      end

    %{
      runs: capture_integer(text, ~r/^\s*runs\s*=\s*(\d+)/m),
      last_exit_code: capture_integer(text, ~r/^\s*last exit code\s*=\s*(-?\d+)/m),
      properties: properties,
      needs_lwcr_update?: "needs LWCR update" in properties
    }
  end

  @doc """
  True when the parsed job state shows the #1484 stale-registration signature:
  launchd carrying a Lightweight Code Requirement it knows is out of date, and/or
  refusing the spawn with `EX_CONFIG` (78).

  78 is decisive on its own: kazi itself never exits 78 (its own failures return
  1 with a message), so an `EX_CONFIG` from this job means launchd declined to
  execute the binary at all.
  """
  @spec stale_registration?(map()) :: boolean()
  def stale_registration?(%{needs_lwcr_update?: true}), do: true
  def stale_registration?(%{last_exit_code: 78}), do: true
  def stale_registration?(_state), do: false

  @doc """
  The one-line operator explanation + remedy for a stale registration.
  """
  @spec stale_registration_message(map()) :: String.t()
  def stale_registration_message(state) do
    runs = state[:runs]

    "the #{@label} LaunchAgent is registered against a REPLACED binary " <>
      "(launchd reports #{stale_signature(state)}#{run_count(runs)}). launchd is refusing " <>
      "to execute kazi at all -- exit 78 is launchd's EX_CONFIG, never kazi's. " <>
      "Re-register the job: `kazi daemon reregister`."
  end

  defp stale_signature(%{needs_lwcr_update?: true}), do: "`needs LWCR update`"
  defp stale_signature(_), do: "`last exit code = 78: EX_CONFIG`"

  defp run_count(nil), do: ""
  defp run_count(runs), do: ", #{runs} spawn attempt(s)"

  defp capture_integer(text, regex) do
    case Regex.run(regex, text) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  @doc """
  Renders the macOS launchd LaunchAgent plist for the bus daemon.

  Options (all optional):

    * `:kazi_path` — the `kazi` binary to launch (default `"kazi"`, resolved on
      the agent's PATH);
    * `:log_path` — where stdout/stderr are written (default
      `<user-home>/.kazi/busdaemon.log`);
    * `:soft_nofiles` / `:hard_nofiles` — the open-files limits (defaults
      #{@default_soft_nofiles} / #{@default_hard_nofiles}).

  Deterministic: the same options render byte-identically.
  """
  @spec plist(keyword()) :: String.t()
  def plist(opts \\ []) do
    kazi_path = Keyword.get(opts, :kazi_path, "kazi")
    log_path = Keyword.get(opts, :log_path, default_log_path())
    soft = Keyword.get(opts, :soft_nofiles, @default_soft_nofiles)
    hard = Keyword.get(opts, :hard_nofiles, @default_hard_nofiles)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{xml_escape(kazi_path)}</string>
        <string>daemon</string>
        <string>start</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>ThrottleInterval</key>
      <integer>#{@throttle_interval_s}</integer>
      <key>EnvironmentVariables</key>
      <dict>
        <key>#{@supervisor_env}</key>
        <string>launchd</string>
      </dict>
      <key>SoftResourceLimits</key>
      <dict>
        <key>NumberOfFiles</key>
        <integer>#{soft}</integer>
      </dict>
      <key>HardResourceLimits</key>
      <dict>
        <key>NumberOfFiles</key>
        <integer>#{hard}</integer>
      </dict>
      <key>StandardOutPath</key>
      <string>#{xml_escape(log_path)}</string>
      <key>StandardErrorPath</key>
      <string>#{xml_escape(log_path)}</string>
    </dict>
    </plist>
    """
  end

  @doc """
  Renders a Linux systemd USER unit for the bus daemon, carrying `LimitNOFILE`
  (the systemd equivalent of the launchd `NumberOfFiles` limits above).

  Options: `:kazi_path` (default `"kazi"`) and `:nofiles` (default
  #{@default_hard_nofiles}).
  """
  @spec systemd_unit(keyword()) :: String.t()
  def systemd_unit(opts \\ []) do
    kazi_path = Keyword.get(opts, :kazi_path, "kazi")
    nofiles = Keyword.get(opts, :nofiles, @default_hard_nofiles)

    """
    [Unit]
    Description=kazi bus daemon
    After=network.target
    StartLimitIntervalSec=300
    StartLimitBurst=5

    [Service]
    Environment=#{@supervisor_env}=systemd
    ExecStart=#{kazi_path} daemon start
    Restart=on-failure
    RestartSec=#{@throttle_interval_s}
    LimitNOFILE=#{nofiles}

    [Install]
    WantedBy=default.target
    """
  end

  defp default_log_path do
    Path.join([System.user_home() || "~", ".kazi", "busdaemon.log"])
  end

  # launchd plist string values are XML; escape the five predefined entities so a
  # path or binary name with a `&`/`<` never produces malformed plist XML.
  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
