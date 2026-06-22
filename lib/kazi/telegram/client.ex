defmodule Kazi.Telegram.Client do
  @moduledoc """
  The transport contract for the Telegram bridge (T3.7a, UC-019, ADR-0011 §3).

  The bridge talks to Telegram only through this **behaviour**, never a concrete
  HTTP client. That is the injectable seam that keeps the bridge hermetically
  testable: tests inject an in-memory double (`test/support`) that records sent
  messages and replays fixture updates, so no bot token and no network are
  touched. A real Bot-API HTTP client is a later, separable adapter (T3.7b/c
  egress + a wiring task) — it is *not* in scope here and pulls no dependency
  into `mix.exs`.

  This module is a **behaviour only** — `@callback` specs, no concrete
  implementation (zero-stub policy: lib/ ships no fake). An adapter implements:

    * `fetch_updates/1` — pull inbound updates (the ingress source). A real
      client wraps `getUpdates`; the double returns its queued fixtures.
    * `send_message/3` — push an outbound message to a chat (the egress sink the
      pings in T3.7b ride). Defined here so the one seam covers both directions.

  ## Implementing

      defmodule MyApp.TelegramHTTP do
        @behaviour Kazi.Telegram.Client

        @impl true
        def fetch_updates(_opts), do: {:ok, [%{"message" => %{...}}]}

        @impl true
        def send_message(_chat_id, _text, _opts), do: {:ok, %{...}}
      end
  """

  @typedoc "Client options (e.g. an offset, a double's control pid). Keyword list."
  @type opts :: keyword()

  @typedoc "A raw Telegram update map, as `Kazi.Telegram.Message.from_update/1` parses it."
  @type update :: map()

  @typedoc "An opaque chat identifier the egress routes a reply to."
  @type chat_id :: term()

  @doc """
  Pulls the currently-available inbound updates (raw Telegram update maps).

  Returns `{:ok, updates}` — possibly an empty list when nothing is waiting — or
  `{:error, reason}` when the transport could not be reached.
  """
  @callback fetch_updates(opts :: opts()) :: {:ok, [update()]} | {:error, term()}

  @doc """
  Sends `text` to `chat_id` (the egress path, used by T3.7b for terminal pings).

  Returns `{:ok, sent}` with the transport's send result, or `{:error, reason}`.
  """
  @callback send_message(chat_id :: chat_id(), text :: String.t(), opts :: opts()) ::
              {:ok, term()} | {:error, term()}
end
