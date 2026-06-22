defmodule Kazi.TelegramTest do
  @moduledoc """
  T3.7a (UC-019): the `Kazi.Telegram` ingress turns a fixture inbound message
  into a `proposed` goal through `Kazi.Authoring.propose/2`, behind an injectable
  client seam.

  Tier 0/1 cover the pure parsing (`Kazi.Telegram.parse_idea/1`,
  `Kazi.Telegram.Message.from_update/1`); Tier 2 crosses the real SQLite boundary
  via `propose/2` (the message persists as `proposed`, round-trips back through
  the read-model). HERMETIC: the Telegram client is the in-memory double (no bot
  token, no network) and the harness is an injected stub (no real `claude`).
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially.
  use ExUnit.Case, async: false

  alias Kazi.Authoring.Draft
  alias Kazi.Goal
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo
  alias Kazi.Telegram
  alias Kazi.Telegram.InMemoryClient
  alias Kazi.Telegram.Message

  # Pure parsing doctests (the `ingest/2` example persists, so it is covered by the
  # Tier-2 tests below rather than as a doctest).
  doctest Kazi.Telegram, only: [parse_idea: 1]
  doctest Kazi.Telegram.Message

  # An injected stub harness (the authoring seam): returns a fixed JSON proposal
  # in the result map's `:result` field — no real claude, no network. The bridge
  # only calls the authoring API; it never touches the harness directly.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @proposal ~s({
      "name": "Health endpoint",
      "predicates": [
        {"id": "health", "provider": "http_probe",
         "description": "GET /healthz returns 200"}
      ]
    })

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{result: @proposal}}
  end

  # An inbound update as a raw Bot-API payload (the shape getUpdates carries).
  defp update(text, chat_id) do
    %{"message" => %{"message_id" => 7, "chat" => %{"id" => chat_id}, "text" => text}}
  end

  setup do
    # Per-test transaction via the SQLite3 Sandbox — isolates rows between tests.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "ingest/2 — Tier 2 (real SQLite boundary, in-memory client)" do
    test "a fixture inbound message yields a proposed goal through the authoring API" do
      message = %Message{chat_id: 42, text: "a health endpoint that returns 200"}

      assert {:ok, %Draft{} = draft} =
               Telegram.ingest(message, authoring: [harness: StubHarness])

      # A create-mode goal with an acceptance predicate, status proposed.
      assert %Goal{mode: :create} = draft.goal
      assert [%{acceptance?: true}] = draft.goal.predicates
      assert draft.status == :proposed
      assert draft.idea == "a health endpoint that returns 200"

      # Persisted as `proposed` in the read-model — round-trips back.
      assert %ProposedGoal{status: "proposed"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
    end

    test "strips a leading bot command before authoring" do
      message = %Message{chat_id: 1, text: "/propose a health endpoint that returns 200"}

      assert {:ok, %Draft{idea: "a health endpoint that returns 200"}} =
               Telegram.ingest(message, authoring: [harness: StubHarness])
    end

    test "rejects an empty message before reaching the authoring API" do
      assert {:error, :empty_message} =
               Telegram.ingest(%Message{chat_id: 1, text: "   "},
                 authoring: [harness: StubHarness]
               )

      # Nothing was proposed.
      assert Repo.aggregate(ProposedGoal, :count) == 0
    end

    test "rejects a bare command with no idea" do
      assert {:error, :empty_message} =
               Telegram.ingest(%Message{chat_id: 1, text: "/propose"},
                 authoring: [harness: StubHarness]
               )
    end
  end

  describe "poll/1 — drives the ingress via the injected client double" do
    test "ingests each parsable update from the in-memory client" do
      client =
        InMemoryClient.start(
          updates: [
            update("a health endpoint that returns 200", 42),
            update("another health endpoint that returns 200", 99)
          ]
        )

      assert {:ok, results} =
               Telegram.poll(client: client, authoring: [harness: StubHarness])

      assert [{:ok, %Draft{}}, {:ok, %Draft{}}] = results
      assert Repo.aggregate(ProposedGoal, :count) == 2
    end

    test "skips non-text updates (a sticker is not an idea)" do
      client =
        InMemoryClient.start(
          updates: [
            update("a health endpoint that returns 200", 42),
            %{"message" => %{"chat" => %{"id" => 5}, "sticker" => %{"file_id" => "x"}}}
          ]
        )

      assert {:ok, [{:ok, %Draft{}}]} =
               Telegram.poll(client: client, authoring: [harness: StubHarness])

      assert Repo.aggregate(ProposedGoal, :count) == 1
    end

    test "surfaces an empty-message update as a per-update error, not a crash" do
      client = InMemoryClient.start(updates: [update("   ", 42)])

      assert {:ok, [{:error, :empty_message}]} =
               Telegram.poll(client: client, authoring: [harness: StubHarness])
    end

    test "surfaces a client that could not be polled" do
      defmodule UnreachableClient do
        @behaviour Kazi.Telegram.Client
        @impl true
        def fetch_updates(_opts), do: {:error, :timeout}
        @impl true
        def send_message(_chat, _text, _opts), do: {:error, :timeout}
      end

      assert {:error, :timeout} =
               Telegram.poll(client: UnreachableClient, authoring: [harness: StubHarness])
    end
  end

  describe "parse_idea/1 — Tier 0 (pure)" do
    test "returns trimmed prose for a plain message" do
      assert {:ok, "ship a /healthz route"} = Telegram.parse_idea("  ship a /healthz route  ")
    end

    test "strips a leading bot command, keeping the idea (incl. its own slashes)" do
      assert {:ok, "ship a /healthz route"} =
               Telegram.parse_idea("/propose ship a /healthz route")

      assert {:ok, "ship a /healthz route"} =
               Telegram.parse_idea("/propose@kazi_bot ship a /healthz route")
    end

    test "rejects blank and bare-command messages" do
      assert {:error, :empty_message} = Telegram.parse_idea("   ")
      assert {:error, :empty_message} = Telegram.parse_idea("")
      assert {:error, :empty_message} = Telegram.parse_idea("/propose")
      assert {:error, :empty_message} = Telegram.parse_idea(nil)
    end
  end

  describe "Message.from_update/1 — Tier 0 (pure)" do
    test "parses chat id, text, and message id from a raw update" do
      assert {:ok, %Message{chat_id: 42, text: "hello", message_id: 7}} =
               Message.from_update(update("hello", 42))
    end

    test "parses an atom-keyed fixture payload" do
      assert {:ok, %Message{chat_id: 5, text: "hi"}} =
               Message.from_update(%{message: %{chat: %{id: 5}, text: "hi"}})
    end

    test "rejects an update with no text message" do
      assert {:error, :unparseable} =
               Message.from_update(%{"message" => %{"chat" => %{"id" => 1}, "sticker" => %{}}})

      assert {:error, :unparseable} = Message.from_update(%{"edited_channel_post" => %{}})
      assert {:error, :unparseable} = Message.from_update(%{})
      assert {:error, :unparseable} = Message.from_update("not a map")
    end
  end
end
