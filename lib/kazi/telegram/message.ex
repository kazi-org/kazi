defmodule Kazi.Telegram.Message do
  @moduledoc """
  An inbound Telegram message the bridge ingests (T3.7a, UC-019, ADR-0011).

  The bridge is a *transport* over `Kazi.Authoring`: it carries a human's prose
  idea in from a chat and a ping back out (T3.7b). This struct is the parsed
  inbound half — the minimal shape the ingress needs to turn a chat message into
  a proposed goal, decoupled from the wire format of a particular Telegram
  client (ADR-0011 §3: the client is an injectable seam).

  Fields:

    * `chat_id` — the chat the message came from, so a reply/ping can be routed
      back (egress, T3.7b). An opaque identifier (Telegram uses integers; we keep
      it as a term so the double and a future real client agree on shape).
    * `text` — the verbatim message text. The bridge parses the *idea* out of
      this (`Kazi.Telegram.parse_idea/1`); an empty/blank text is a no-op error.
    * `message_id` — the inbound message's id, when the transport supplies one.
      Carried through for de-duplication / reply threading; not required by the
      ingress.
  """

  @typedoc "An opaque chat identifier (a Telegram chat id), used to route egress."
  @type chat_id :: term()

  @type t :: %__MODULE__{
          chat_id: chat_id(),
          text: String.t(),
          message_id: term() | nil
        }

  @enforce_keys [:chat_id, :text]
  defstruct chat_id: nil, text: nil, message_id: nil

  @doc """
  Builds a `Message` from a raw Telegram update map (string- or atom-keyed), the
  shape a Bot API `getUpdates`/webhook payload carries under `"message"`.

  Pure and total. Returns `{:ok, message}` with the chat id and text extracted,
  or `{:error, :unparseable}` when the payload has no `message.chat.id` +
  `message.text` (e.g. a non-text update like a sticker or a callback query the
  ingress cannot turn into an idea).

  ## Examples

      iex> Kazi.Telegram.Message.from_update(%{
      ...>   "message" => %{
      ...>     "message_id" => 7,
      ...>     "chat" => %{"id" => 42},
      ...>     "text" => "ship a /healthz route"
      ...>   }
      ...> })
      {:ok, %Kazi.Telegram.Message{chat_id: 42, text: "ship a /healthz route", message_id: 7}}

      iex> Kazi.Telegram.Message.from_update(%{"message" => %{"sticker" => %{}}})
      {:error, :unparseable}
  """
  @spec from_update(map()) :: {:ok, t()} | {:error, :unparseable}
  def from_update(update) when is_map(update) do
    with {:ok, message} <- fetch(update, "message"),
         {:ok, chat} <- fetch(message, "chat"),
         {:ok, chat_id} <- fetch(chat, "id"),
         {:ok, text} when is_binary(text) <- fetch(message, "text") do
      {:ok, %__MODULE__{chat_id: chat_id, text: text, message_id: get(message, "message_id")}}
    else
      _ -> {:error, :unparseable}
    end
  end

  def from_update(_other), do: {:error, :unparseable}

  # Fetch a key that may be present under a string or atom key (a raw JSON-decoded
  # payload is string-keyed; a hand-built fixture may use atoms).
  defp fetch(map, key) when is_map(map) do
    case get(map, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end
end
