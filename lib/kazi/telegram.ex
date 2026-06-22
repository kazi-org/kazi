defmodule Kazi.Telegram do
  @moduledoc """
  The Telegram bridge: ingress from a chat message to a proposed goal (T3.7a) and
  egress of a terminal-event ping back out (T3.7b) — UC-019, ADR-0011.

  The bridge is a **transport** over the authoring API and the loop's *terminal
  result*, not a part of the core loop. A human sends kazi a prose idea in a
  Telegram message; the bridge parses the idea out and hands it to
  `Kazi.Authoring.propose/2`, which drives the harness to draft acceptance
  predicates and persists a `proposed` goal. The bridge never reaches into
  `Kazi.Loop` or `Kazi.Harness.*` — the only WRITE it triggers is authoring,
  through the same API the CLI and dashboard use (ADR-0011 §2).

  ## The seam

  Telegram itself is reached only through `Kazi.Telegram.Client`, an injectable
  behaviour. This keeps the bridge hermetic: tests inject an in-memory double
  that replays fixture updates and records sends, so no bot token and no network
  are touched, and no Telegram HTTP dependency is pulled into the build. A real
  Bot-API client is a later, separable adapter.

  ## Ingress flow (T3.7a)

  1. Pull inbound updates from the injected client (`poll/1`) — or take a single
     already-parsed `Kazi.Telegram.Message` (`ingest/2`).
  2. Parse the *idea* out of the message text (`parse_idea/1`): a blank message
     is a no-op error rather than a vacuous goal.
  3. Drive `Kazi.Authoring.propose/2` with the idea, forwarding the caller's
     authoring opts (the injected stub harness in tests). The result is the
     reviewable `Kazi.Authoring.Draft`.

  ## Egress flow (T3.7b)

  The bridge does NOT subscribe to the loop or reach into it — it is DECOUPLED
  (ADR-0011 §1). The egress is a pure transport step: a caller that already holds
  a loop's terminal `t:Kazi.Loop.result/0` (the value `Kazi.Runtime.run/2`
  returns, or one the wiring task T3.7c hands off) calls `notify/3`, which maps
  the terminal outcome to one human-readable line and sends EXACTLY ONE outbound
  message through the client seam. One terminal event → one `notify/3` call → one
  ping; the function has no internal loop or retry, so there are no duplicate
  pings. The outcome→message map:

    * `:converged`                     — the goal converged (success).
    * `:stopped` with reason `:stuck`  — the loop got stuck and escalated.
    * `:stopped` (operator stop)       — the loop was stopped before converging.
    * `:over_budget`                   — a budget ceiling was hit; the reason
      names the exceeded dimension (`:max_iterations` / `:wall_clock` /
      `:token_budget`).
  """

  alias Kazi.Authoring
  alias Kazi.Loop
  alias Kazi.Telegram.Message

  @typedoc """
  Options threaded through ingestion:

    * `:authoring` — opts forwarded verbatim to `Kazi.Authoring.propose/2`
      (e.g. `:harness` to inject the stub adapter, `:workspace`). Default `[]`.
    * `:client` / `:client_opts` — the `Kazi.Telegram.Client` module and its
      opts, used by `poll/1` to pull updates. `ingest/2` does not need a client.
  """
  @type opts :: keyword()

  @doc """
  Ingests a single inbound `Kazi.Telegram.Message` into a proposed goal.

  Parses the idea from the message text and drives `Kazi.Authoring.propose/2`,
  forwarding the `:authoring` opts (the injected harness in tests). Returns
  `{:ok, %Kazi.Authoring.Draft{}}` — the reviewable artifact, status `proposed`
  — or an error:

    * `{:error, :empty_message}` — the message carried no usable idea text.
    * any `Kazi.Authoring.propose/2` error (`{:harness_failed, _}`,
      `{:invalid_proposal, _}`, an `Ecto.Changeset`) passed through.

  ## Examples

      iex> defmodule OneShotHarness do
      ...>   @behaviour Kazi.HarnessAdapter
      ...>   @impl true
      ...>   def run(_p, _w, _o) do
      ...>     {:ok, %{result: ~s({"predicates":[{"id":"h","provider":"http_probe"}]})}}
      ...>   end
      ...> end
      iex> msg = %Kazi.Telegram.Message{chat_id: 1, text: "a health endpoint"}
      iex> {:ok, draft} = Kazi.Telegram.ingest(msg, authoring: [harness: OneShotHarness])
      iex> draft.status
      :proposed
  """
  @spec ingest(Message.t(), opts()) :: {:ok, Authoring.Draft.t()} | {:error, term()}
  def ingest(%Message{} = message, opts \\ []) when is_list(opts) do
    with {:ok, idea} <- parse_idea(message.text) do
      Authoring.propose(idea, Keyword.get(opts, :authoring, []))
    end
  end

  @doc """
  Sends EXACTLY ONE terminal-event ping to `chat_id` through the client seam.

  The egress half of the bridge (T3.7b, UC-019). Takes the loop's terminal
  `t:Kazi.Loop.result/0` (what `Kazi.Runtime.run/2` returns) — or a bare
  `t:Kazi.Loop.outcome/0` when there is no reason to convey — maps it to one
  human-readable line (`render/1`) and sends it via the injected
  `Kazi.Telegram.Client`. One terminal event yields one call yields one ping:
  there is no internal loop or retry, so no duplicate pings.

  The bridge stays DECOUPLED from the loop (ADR-0011 §1): `notify/3` does not
  observe or reach into `Kazi.Loop`; the caller that already holds the terminal
  result drives it. Returns the client's `send_message/3` result —
  `{:ok, sent}` or `{:error, reason}` (the latter when the transport could not be
  reached; in tests the in-memory double always succeeds).

  ## Options

    * `:client` — the `Kazi.Telegram.Client` module (required).
    * `:client_opts` — opts forwarded verbatim to the client's `send_message/3`
      (default `[]`).

  ## Examples

      iex> client = Kazi.Telegram.InMemoryClient.start()
      iex> {:ok, _sent} =
      ...>   Kazi.Telegram.notify(42, %{outcome: :converged, reason: nil}, client: client)
      iex> [{42, text, _opts}] = Kazi.Telegram.InMemoryClient.sent()
      iex> text =~ "converged"
      true
  """
  @spec notify(Message.chat_id(), Loop.result() | Loop.outcome(), opts()) ::
          {:ok, term()} | {:error, term()}
  def notify(chat_id, result_or_outcome, opts) when is_list(opts) do
    client = Keyword.fetch!(opts, :client)
    client_opts = Keyword.get(opts, :client_opts, [])

    client.send_message(chat_id, render(result_or_outcome), client_opts)
  end

  # Map a terminal loop result (or bare outcome) to one human-readable line. The
  # result carries the outcome and the reason that disambiguates a `:stopped`
  # (operator stop vs. `:stuck` escalation) and names the exceeded budget
  # dimension on `:over_budget`. A bare outcome (no reason) renders the
  # outcome's default line.
  @spec render(Loop.result() | Loop.outcome()) :: String.t()
  defp render(%{outcome: outcome, reason: reason}), do: render_outcome(outcome, reason)
  defp render(outcome) when is_atom(outcome), do: render_outcome(outcome, nil)

  defp render_outcome(:converged, _reason),
    do: "✅ kazi converged the goal — every acceptance predicate is satisfied."

  defp render_outcome(:stopped, :stuck),
    do: "⚠️ kazi got stuck — the same predicates kept failing, so it escalated to a human."

  defp render_outcome(:stopped, _reason),
    do: "🛑 kazi stopped the loop before the goal converged."

  defp render_outcome(:over_budget, reason),
    do: "⏳ kazi hit its budget ceiling (#{budget_dimension(reason)}) before converging."

  # Render the exceeded budget dimension for an over-budget ping; falls back to a
  # neutral phrase when the reason is absent (a bare `:over_budget` outcome).
  defp budget_dimension(:max_iterations), do: "max iterations"
  defp budget_dimension(:wall_clock), do: "wall-clock time"
  defp budget_dimension(:token_budget), do: "token budget"
  defp budget_dimension(nil), do: "budget exhausted"
  defp budget_dimension(other), do: to_string(other)

  @doc """
  Polls the injected client for inbound updates and ingests each parsable one.

  Pulls updates via the `:client` module's `fetch_updates/1`, parses each into a
  `Kazi.Telegram.Message` and ingests it. Returns `{:ok, results}` — one entry
  per *parsable* update, each `{:ok, draft}` or `{:error, reason}` from
  `ingest/2`; updates that are not text messages (`from_update/1` rejects them)
  are skipped, not surfaced as errors. Returns `{:error, reason}` when the client
  could not be polled.

  The client is the seam: tests inject the in-memory double, so this drives the
  whole ingress path with no bot token and no network.
  """
  @spec poll(opts()) :: {:ok, [{:ok, Authoring.Draft.t()} | {:error, term()}]} | {:error, term()}
  def poll(opts) when is_list(opts) do
    client = Keyword.fetch!(opts, :client)
    client_opts = Keyword.get(opts, :client_opts, [])

    case client.fetch_updates(client_opts) do
      {:ok, updates} when is_list(updates) ->
        results =
          updates
          |> Enum.flat_map(fn update ->
            case Message.from_update(update) do
              {:ok, message} -> [ingest(message, opts)]
              {:error, :unparseable} -> []
            end
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses the prose *idea* out of an inbound message `text`.

  Pure and total. Strips a leading bot command (e.g. `/propose ship a route` →
  `ship a route`) and surrounding whitespace, so a slash-command-style message
  authors the same goal as the bare idea. Returns `{:ok, idea}`, or
  `{:error, :empty_message}` when nothing usable remains (a blank message, or a
  bare command with no idea after it).

  ## Examples

      iex> Kazi.Telegram.parse_idea("/propose ship a /healthz route")
      {:ok, "ship a /healthz route"}

      iex> Kazi.Telegram.parse_idea("   ")
      {:error, :empty_message}
  """
  @spec parse_idea(String.t() | nil) :: {:ok, String.t()} | {:error, :empty_message}
  def parse_idea(text) when is_binary(text) do
    case text |> strip_command() |> String.trim() do
      "" -> {:error, :empty_message}
      idea -> {:ok, idea}
    end
  end

  def parse_idea(_text), do: {:error, :empty_message}

  # Drop a leading bot command token (`/propose`, `/propose@kazi_bot`) so a
  # command-prefixed message and the bare idea author the same goal. A message
  # that is not command-prefixed passes through unchanged.
  defp strip_command(text) do
    case String.split(String.trim_leading(text), ~r/\s+/, parts: 2) do
      ["/" <> _command, rest] -> rest
      ["/" <> _command] -> ""
      _ -> text
    end
  end
end
