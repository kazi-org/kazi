defmodule Kazi.Daemon.LaunchAgentTest do
  @moduledoc """
  T66.6 (#1579): the shipped service templates carry EXPLICIT high file-descriptor
  limits, so the bus daemon cannot go alive-but-deaf on `accept failed: :emfile`
  under fleet churn (launchd defaults to 256 open files).

  Also #1484 (ADR-0083): exit 78 is launchd's own `EX_CONFIG` -- kazi is never
  executed, because the registered job's Lightweight Code Requirement went stale
  under an in-place binary upgrade. `parse_job_state/1` + `stale_registration?/1`
  detect that (pure, from `launchctl print` TEXT, so no real job is ever
  registered in this suite) and `reregister_argv/2` is the re-registration remedy
  as pure, testable argv. The SAME issue's crashloop (33,035 spawn attempts
  against a permanently-failing precondition) is why `KeepAlive` is now
  conditional (`SuccessfulExit: false`) rather than unconditional.
  """
  use ExUnit.Case, async: true

  alias Kazi.Daemon.LaunchAgent

  describe "launchd plist" do
    test "carries explicit high SoftResourceLimits/HardResourceLimits NumberOfFiles" do
      plist = LaunchAgent.plist()

      # The emfile fix: both limits present, well above the launchd default of 256.
      assert plist =~ "<key>SoftResourceLimits</key>"
      assert plist =~ "<key>HardResourceLimits</key>"
      assert plist =~ "<key>NumberOfFiles</key>"
      assert plist =~ "<integer>#{LaunchAgent.default_soft_nofiles()}</integer>"
      assert plist =~ "<integer>#{LaunchAgent.default_hard_nofiles()}</integer>"
      assert LaunchAgent.default_soft_nofiles() >= 4096
      assert LaunchAgent.default_hard_nofiles() >= LaunchAgent.default_soft_nofiles()
    end

    test "launches `kazi daemon start`, runs at load, and keeps alive" do
      plist = LaunchAgent.plist(kazi_path: "/usr/local/bin/kazi")

      assert plist =~ "<string>#{LaunchAgent.label()}</string>"
      assert plist =~ "<string>/usr/local/bin/kazi</string>"
      assert plist =~ "<string>daemon</string>"
      assert plist =~ "<string>start</string>"
      assert plist =~ "<key>RunAtLoad</key>"
      assert plist =~ "<key>KeepAlive</key>"
    end

    test "#1484: KeepAlive is CONDITIONAL (SuccessfulExit: false), not unconditional" do
      plist = LaunchAgent.plist()

      # A plain `<true/>` KeepAlive respawns forever, even against a permanently
      # failing precondition -- the reported crashloop reached 33,035 spawn
      # attempts. `SuccessfulExit: false` only restarts a NON-zero exit, so a
      # deliberate exit 0 (daemon_permanent_error/3, cli.ex) stops the loop.
      assert plist =~ "<key>KeepAlive</key>"
      assert plist =~ "<key>SuccessfulExit</key>"
      assert plist =~ "<false/>"
      refute plist =~ "<key>KeepAlive</key>\n  <true/>"
    end

    test "#1484: carries an explicit ThrottleInterval and names the supervisor via env" do
      plist = LaunchAgent.plist()

      assert plist =~ "<key>ThrottleInterval</key>"
      assert plist =~ "<integer>#{LaunchAgent.throttle_interval_s()}</integer>"
      assert plist =~ "<key>EnvironmentVariables</key>"
      assert plist =~ "<key>#{LaunchAgent.supervisor_env_var()}</key>"
      assert plist =~ "<string>launchd</string>"
    end

    test "overrides the fd limits when asked, and is well-formed XML" do
      plist = LaunchAgent.plist(soft_nofiles: 12_345, hard_nofiles: 54_321)
      assert plist =~ "<integer>12345</integer>"
      assert plist =~ "<integer>54321</integer>"
      assert plist =~ ~s(<?xml version="1.0")
      assert plist =~ "<plist version=\"1.0\">"
      assert plist =~ "</plist>"
    end

    test "XML-escapes a binary path with special characters" do
      plist = LaunchAgent.plist(kazi_path: ~s(/opt/a & b/kazi))
      assert plist =~ "/opt/a &amp; b/kazi"
      refute plist =~ "/opt/a & b/kazi"
    end

    test "is deterministic — same options render byte-identically" do
      assert LaunchAgent.plist(kazi_path: "kazi") == LaunchAgent.plist(kazi_path: "kazi")
    end
  end

  describe "systemd unit (Linux equivalent)" do
    test "carries LimitNOFILE, the systemd equivalent of NumberOfFiles" do
      unit = LaunchAgent.systemd_unit()
      assert unit =~ "LimitNOFILE=#{LaunchAgent.default_hard_nofiles()}"
      assert unit =~ "ExecStart=kazi daemon start"
      assert unit =~ "Restart=on-failure"
    end

    test "#1484: bounds the restart rate (RestartSec + StartLimit*) and names the supervisor" do
      unit = LaunchAgent.systemd_unit()

      assert unit =~ "RestartSec=#{LaunchAgent.throttle_interval_s()}"
      assert unit =~ "StartLimitIntervalSec="
      assert unit =~ "StartLimitBurst="
      assert unit =~ "Environment=#{LaunchAgent.supervisor_env_var()}=systemd"
    end
  end

  describe "operator surface" do
    test "names the label, install path, and the force-restart remedy" do
      assert LaunchAgent.label() == "run.kazi.bushost"
      assert LaunchAgent.plist_install_path() =~ "Library/LaunchAgents/run.kazi.bushost.plist"
      # The kickstart remedy the CLI errors point operators at.
      assert LaunchAgent.kickstart_command() =~ "launchctl kickstart -k"
      assert LaunchAgent.kickstart_command() =~ "run.kazi.bushost"
    end

    test "#1484: reregister_command bootouts then bootstraps the SAME plist" do
      cmd = LaunchAgent.reregister_command()

      assert cmd =~ "launchctl bootout gui/$(id -u)/run.kazi.bushost"
      assert cmd =~ "launchctl bootstrap gui/$(id -u) #{LaunchAgent.plist_install_path()}"
      # bootout must run BEFORE bootstrap -- re-registering means dropping the
      # stale registration first, then re-pinning against the current binary.
      assert String.contains?(cmd, "bootout") and
               String.contains?(cmd, "bootstrap") and
               cmd |> String.split("bootout") |> List.last() |> String.contains?("bootstrap")
    end

    test "#1484: reregister_argv is pure argv, bootout before bootstrap, using the given uid/path" do
      steps = LaunchAgent.reregister_argv("501", "/tmp/some.plist")

      assert steps == [
               {"launchctl", ["bootout", "gui/501/run.kazi.bushost"]},
               {"launchctl", ["bootstrap", "gui/501", "/tmp/some.plist"]}
             ]
    end

    test "#1484: print_argv names the job to inspect" do
      assert LaunchAgent.print_argv("501") == {"launchctl", ["print", "gui/501/run.kazi.bushost"]}
    end
  end

  describe "supervised?/1 and supervisor/1 (#1484 defect 2)" do
    test "false with no KAZI_SUPERVISOR" do
      refute LaunchAgent.supervised?(%{})
      assert LaunchAgent.supervisor(%{}) == nil
    end

    test "true when the shipped launchd template's env var is set" do
      assert LaunchAgent.supervised?(%{"KAZI_SUPERVISOR" => "launchd"})
      assert LaunchAgent.supervisor(%{"KAZI_SUPERVISOR" => "launchd"}) == "launchd"
    end

    test "true when the shipped systemd unit's env var is set" do
      assert LaunchAgent.supervised?(%{"KAZI_SUPERVISOR" => "systemd"})
      assert LaunchAgent.supervisor(%{"KAZI_SUPERVISOR" => "systemd"}) == "systemd"
    end

    test "an unrecognized value is NOT treated as supervised (never guess)" do
      refute LaunchAgent.supervised?(%{"KAZI_SUPERVISOR" => "something_else"})
    end
  end

  describe "parse_job_state/1 and stale_registration?/1 (#1484 defect 1)" do
    test "detects `needs LWCR update` as stale" do
      text = """
      program = /opt/homebrew/bin/kazi
      runs = 33035
      last exit code = 78: EX_CONFIG
      state = spawn scheduled
      properties = keepalive | runatload | needs LWCR update | managed LWCR | has LWCR
      """

      state = LaunchAgent.parse_job_state(text)

      assert state.runs == 33_035
      assert state.last_exit_code == 78
      assert state.needs_lwcr_update? == true
      assert "needs LWCR update" in state.properties
      assert LaunchAgent.stale_registration?(state)
      assert LaunchAgent.stale_registration_message(state) =~ "needs LWCR update"
      assert LaunchAgent.stale_registration_message(state) =~ "kazi daemon reregister"
    end

    test "exit 78 alone (no needs-LWCR-update property) is still decisive" do
      text = """
      runs = 12
      last exit code = 78: EX_CONFIG
      properties = keepalive | runatload
      """

      state = LaunchAgent.parse_job_state(text)

      refute state.needs_lwcr_update?
      assert LaunchAgent.stale_registration?(state)
      assert LaunchAgent.stale_registration_message(state) =~ "EX_CONFIG"
    end

    test "a healthy job (re-registered, per the confirming experiment) is NOT stale" do
      text = """
      runs = 2
      last exit code = 1
      properties = keepalive | runatload
      """

      state = LaunchAgent.parse_job_state(text)

      assert state.last_exit_code == 1
      refute LaunchAgent.stale_registration?(state)
    end

    test "unparseable/absent fields come back nil, never guessed" do
      state = LaunchAgent.parse_job_state("some unrelated text")

      assert state.runs == nil
      assert state.last_exit_code == nil
      assert state.properties == []
      refute state.needs_lwcr_update?
      refute LaunchAgent.stale_registration?(state)
    end
  end
end
