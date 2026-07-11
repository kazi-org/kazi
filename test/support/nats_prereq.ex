defmodule Kazi.TestSupport.NatsPrereq do
  @moduledoc """
  T51.2 (ADR-0067): `Kazi.Daemon.start/1` unconditionally supervises
  nats-server, so any test starting the daemon tree without it on PATH fails
  inside `start_supervised!` with an opaque MatchError instead of a clear
  reason. `ensure!/0` turns that into ONE actionable line before the daemon is
  ever started, pointing at the CI install step / https://nats.io/download/
  instead of the environment.
  """

  @spec ensure!() :: :ok
  def ensure! do
    if is_nil(System.find_executable("nats-server")) do
      raise """
      nats-server binary not found on PATH.

      Daemon tests supervise a real nats-server process (T51.2, ADR-0067) and \
      cannot run without it. Install it locally (e.g. `brew install nats-server` \
      or https://nats.io/download/); CI installs a pinned version in \
      .github/workflows/ci.yml.
      """
    end

    :ok
  end
end
