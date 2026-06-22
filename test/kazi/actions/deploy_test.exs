defmodule Kazi.Actions.DeployTest do
  @moduledoc """
  Tier 2 boundary test for the deploy action (T0.10b, UC-015).

  The deployer command is injectable, so these tests point it at a STUB script
  that emulates `gcloud run deploy` — echoing its args to a side file and
  printing a fake service URL — with no real cloud call. We assert the action
  invokes the deployer with the right `run deploy` argument vector and returns
  the parsed deploy ref, and that a non-zero exit becomes an `{:error, ...}`
  result rather than an exception.
  """
  use ExUnit.Case, async: true

  alias Kazi.Action
  alias Kazi.Actions.Deploy

  @fake_url "https://kazi-deploy-target-abc123-uc.a.run.app"

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_deploy_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    args_file = Path.join(dir, "args.txt")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, args_file: args_file}
  end

  # A stub that emulates `gcloud run deploy`: it records the args it was called
  # with, prints a (possibly multi-line) fake service URL on stdout, and exits 0.
  defp ok_stub(path, args_file, url) do
    script = """
    #!/bin/sh
    # Record every argument, one per line, so the test can assert on them.
    for a in "$@"; do echo "$a" >> "#{args_file}"; done
    # gcloud build-from-source emits progress before the final value(status.url);
    # emulate that so the parser must pick the last line.
    echo "Building and deploying from source..."
    echo "#{url}"
    exit 0
    """

    write_executable(path, script)
  end

  # A stub that emulates a failed deploy: prints an error and exits non-zero.
  defp fail_stub(path) do
    script = """
    #!/bin/sh
    echo "ERROR: (gcloud.run.deploy) PERMISSION_DENIED" 1>&2
    exit 1
    """

    write_executable(path, script)
  end

  defp write_executable(path, script) do
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp deploy_action(cmd, extra \\ %{}) do
    params =
      Map.merge(
        %{
          cmd: cmd,
          service: "kazi-deploy-target",
          project: "my-proj",
          region: "us-central1",
          source: "fixtures/deploy-target"
        },
        extra
      )

    Action.new(:deploy, params: params)
  end

  test "invokes the deployer with the right args and returns the parsed deploy ref",
       %{dir: dir, args_file: args_file} do
    stub = ok_stub(Path.join(dir, "gcloud_ok"), args_file, @fake_url)

    assert {:ok, result} = Deploy.execute(deploy_action(stub), %{})

    # The deploy ref is the printed service URL (last line of stdout).
    assert result.deploy_ref == @fake_url
    assert result.url == @fake_url
    assert result.service == "kazi-deploy-target"

    # The deployer was invoked as `gcloud run deploy <service> --source ...`.
    args = File.read!(args_file) |> String.split("\n", trim: true)
    assert ["run", "deploy", "kazi-deploy-target" | rest] = args
    assert "--source" in rest
    assert "fixtures/deploy-target" in rest
    assert "--project" in rest
    assert "my-proj" in rest
    assert "--region" in rest
    assert "us-central1" in rest
    assert "--port" in rest
    assert "8080" in rest
    assert "--allow-unauthenticated" in rest
    assert "--quiet" in rest
    assert "--format" in rest
    assert "value(status.url)" in rest
  end

  test "honours custom port and omits --allow-unauthenticated when disabled",
       %{dir: dir, args_file: args_file} do
    stub = ok_stub(Path.join(dir, "gcloud_ok"), args_file, @fake_url)

    action = deploy_action(stub, %{port: 9000, allow_unauthenticated: false})
    assert {:ok, _} = Deploy.execute(action, %{})

    args = File.read!(args_file) |> String.split("\n", trim: true)
    assert "9000" in args
    refute "--allow-unauthenticated" in args
  end

  test "a non-zero exit becomes an error result (no exception)", %{dir: dir} do
    stub = fail_stub(Path.join(dir, "gcloud_fail"))

    assert {:error, {:deploy_failed, 1, output}} = Deploy.execute(deploy_action(stub), %{})
    assert output =~ "PERMISSION_DENIED"
  end

  test "deployer command can be injected via context", %{dir: dir, args_file: args_file} do
    stub = ok_stub(Path.join(dir, "gcloud_ctx"), args_file, @fake_url)

    # No :cmd in params; supply it through the execution context instead.
    params = %{
      service: "svc",
      project: "p",
      region: "r",
      source: "."
    }

    action = Action.new(:deploy, params: params)

    assert {:ok, %{deploy_ref: @fake_url}} = Deploy.execute(action, %{deploy_cmd: stub})
  end

  test "missing required config returns an error", %{dir: dir, args_file: args_file} do
    stub = ok_stub(Path.join(dir, "gcloud_ok"), args_file, @fake_url)

    action = Action.new(:deploy, params: %{cmd: stub, project: "p", region: "r"})
    assert {:error, {:missing_param, :service}} = Deploy.execute(action, %{})
  end

  test "rejects a non-deploy action kind" do
    assert {:error, {:unsupported_kind, :integrate}} =
             Deploy.execute(Action.new(:integrate), %{})
  end
end
