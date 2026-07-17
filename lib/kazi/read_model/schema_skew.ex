defmodule Kazi.ReadModel.SchemaSkew do
  @moduledoc """
  T52.2 (ADR-0068 decision 3): the client-side schema-version comparison the
  write path branches on.

  When a daemon is up, client and daemon exchange schema versions on the control
  socket (`ping`'s `schema_vsn`, the daemon's stamped `kazi_schema_meta`
  version). `classify/2` compares the CLIENT's `Kazi.ReadModel.Migrate.binary_version/1`
  against that daemon `schema_vsn` and names the three cases the write path
  handles:

    * `:client_newer` — this binary knows a newer schema than the daemon holds
      (the common mid-release-window case). The daemon is older; the operator is
      told to `kazi daemon restart` or continue without persistence (T52.8),
      never a silent blind write.
    * `:client_older` — the daemon holds a newer schema. The daemon's write API
      is additive within a major version, so an older client keeps writing
      through it (T52.5).
    * `:equal` — same schema; write straight through.

  Pure and side-effect-free: it decides nothing about I/O, it only classifies
  two integers. No writer is routed here (that is T52.5+); this is the
  comparison those tasks consume.
  """

  @typedoc "The three version-skew cases the write path branches on."
  @type classification :: :equal | :client_older | :client_newer

  @doc """
  Classify the client's schema version against the daemon's reported `schema_vsn`.

  Both are integer migration timestamps (`Kazi.ReadModel.Migrate.binary_version/1`
  and the `ping` `schema_vsn`).
  """
  @spec classify(integer(), integer()) :: classification()
  def classify(client_version, daemon_schema_vsn)
      when is_integer(client_version) and is_integer(daemon_schema_vsn) do
    cond do
      client_version > daemon_schema_vsn -> :client_newer
      client_version < daemon_schema_vsn -> :client_older
      true -> :equal
    end
  end
end
