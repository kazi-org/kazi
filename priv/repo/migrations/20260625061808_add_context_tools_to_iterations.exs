defmodule Kazi.Repo.Migrations.AddContextToolsToIterations do
  @moduledoc """
  T34.3 (ADR-0046 §2): persist the per-iteration `context` + `tools` counters so
  the cached-vs-fresh context spend and the agent's tool-call breakdown are
  queryable from the read-model — the signals the E19 token-economy arms attribute
  outcomes to (a working stable prefix shows rising cached reads + falling
  file/search calls).

  Additive, backward-compatible JSON-map columns on the existing iteration /
  evidence log, each defaulting to an empty object. Iterations recorded before
  this migration (or with no dispatch / no harness tool-use stream) carry `{}`.
  """

  use Ecto.Migration

  def change do
    alter table(:iterations) do
      # The context counters: orientation/retrieval cache state + section token
      # estimates (T34.3). `:map` is JSON on SQLite; default to the empty object.
      add :context, :map, default: %{}
      # The tool counters: tool_calls / file_reads / search_calls / graph_calls
      # (T34.3). Empty when the harness exposed no tool-use stream (absent ≠ zero).
      add :tools, :map, default: %{}
    end
  end
end
