defmodule Kazi.Telegram.InMemoryClient do
  @moduledoc """
  A pure, hermetic `Kazi.Telegram.Client` double for tests (T3.7a, ADR-0011 §3):
  an in-memory Telegram transport that replays queued inbound updates and records
  outbound sends, so the bridge's ingress (and the T3.7b egress) is exercised with
  no bot token and no network.

  Lives only in `test/` (zero-stub policy: no doubles in `lib/`). The backing store
  is the calling process's dictionary, so each test is isolated without an external
  process and the behaviour callbacks stay arity-faithful (no pid threading) — the
  same pattern as `Kazi.Context.InMemoryPackCache`.

  ## Usage

      Kazi.Telegram.InMemoryClient.start(updates: [fixture_update])
      Kazi.Telegram.poll(client: Kazi.Telegram.InMemoryClient, authoring: [harness: Stub])
      Kazi.Telegram.InMemoryClient.sent()  #=> [{chat_id, text, opts}]
  """

  @behaviour Kazi.Telegram.Client

  @doc """
  Starts a fresh in-memory client for the test and returns this module (to pass as
  `:client`). `:updates` seeds the inbound queue `fetch_updates/1` will replay
  (default `[]`). Outbound `send_message/3` calls start empty and accumulate in
  `sent/0`. The backing store is the calling process's dictionary, so each test is
  isolated.
  """
  @spec start(keyword()) :: module()
  def start(opts \\ []) do
    Process.put(__MODULE__, %{updates: Keyword.get(opts, :updates, []), sent: []})
    __MODULE__
  end

  @doc "The outbound messages recorded so far, oldest first: `[{chat_id, text, opts}]`."
  @spec sent() :: [{term(), String.t(), keyword()}]
  def sent do
    Process.get(__MODULE__, %{sent: []}) |> Map.get(:sent, []) |> Enum.reverse()
  end

  @impl Kazi.Telegram.Client
  def fetch_updates(_opts) do
    {:ok, Process.get(__MODULE__, %{updates: []}) |> Map.get(:updates, [])}
  end

  @impl Kazi.Telegram.Client
  def send_message(chat_id, text, opts) do
    store = Process.get(__MODULE__, %{sent: []})

    Process.put(
      __MODULE__,
      Map.update(store, :sent, [{chat_id, text, opts}], &[{chat_id, text, opts} | &1])
    )

    {:ok, %{chat_id: chat_id, text: text}}
  end
end
