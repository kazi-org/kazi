defmodule Kazi.Authoring.Clarify.Option do
  @moduledoc """
  One selectable answer to a clarifying `Kazi.Authoring.Clarify.Question`
  (T11.1, UC-029, ADR-0019).

  An option pairs the human-readable `label` shown in the terminal with the
  stable `value` recorded as the answer and folded into the draft prompt. Keeping
  the two distinct lets the rendering change without changing what the draft sees.
  """

  @type t :: %__MODULE__{label: String.t(), value: String.t()}

  @enforce_keys [:label, :value]
  defstruct label: nil, value: nil

  @doc """
  Builds an option from its display `label` and stable `value`.

      iex> Kazi.Authoring.Clarify.Option.new("200, no auth", "200_public")
      %Kazi.Authoring.Clarify.Option{label: "200, no auth", value: "200_public"}
  """
  @spec new(String.t(), String.t()) :: t()
  def new(label, value) when is_binary(label) and is_binary(value) do
    %__MODULE__{label: label, value: value}
  end
end
