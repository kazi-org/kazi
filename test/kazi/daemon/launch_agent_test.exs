defmodule Kazi.Daemon.LaunchAgentTest do
  @moduledoc """
  T66.6 (#1579): the shipped service templates carry EXPLICIT high file-descriptor
  limits, so the bus daemon cannot go alive-but-deaf on `accept failed: :emfile`
  under fleet churn (launchd defaults to 256 open files).
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
  end

  describe "operator surface" do
    test "names the label, install path, and the force-restart remedy" do
      assert LaunchAgent.label() == "run.kazi.bushost"
      assert LaunchAgent.plist_install_path() =~ "Library/LaunchAgents/run.kazi.bushost.plist"
      # The kickstart remedy the CLI errors point operators at.
      assert LaunchAgent.kickstart_command() =~ "launchctl kickstart -k"
      assert LaunchAgent.kickstart_command() =~ "run.kazi.bushost"
    end
  end
end
