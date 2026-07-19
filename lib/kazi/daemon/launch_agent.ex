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

  This module only RENDERS the templates (pure, deterministic) and names the
  install path + reload command; installing them is an operator step documented
  in `docs/session-bus.md`. Rendering is the shipped, greppable, test-pinned
  source of truth for the fd-limit contract.
  """

  @label "run.kazi.bushost"

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

  @doc """
  The `launchctl` command that force-restarts the agent — the operator remedy
  when the daemon is alive-but-deaf (emfile, wedged) and `KeepAlive` cannot
  recover it on its own.
  """
  @spec kickstart_command() :: String.t()
  def kickstart_command, do: "launchctl kickstart -k gui/$(id -u)/#{@label}"

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
      <true/>
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

    [Service]
    ExecStart=#{kazi_path} daemon start
    Restart=on-failure
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
