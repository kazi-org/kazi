defmodule Kazi.Authoring.Clarify.Question do
  @moduledoc """
  One clarifying question asked before a goal is drafted (T11.1, UC-029,
  ADR-0019).

  A question is a small, pure data shape so both the deterministic floor
  (`Kazi.Authoring.Clarify.gaps/2`) and the harness-drafted candidates (T11.3)
  produce the same thing, the CLI renders it as terminal multiple-choice (T11.6),
  and `Kazi.Authoring.Clarify.fold_answers/2` folds the answer into the draft
  prompt. Fields:

    * `id` -- a stable key the answer is recorded under (e.g. `"live-target"`).
    * `prompt` -- the question text shown to the author.
    * `options` -- the selectable `Kazi.Authoring.Clarify.Option` choices.
    * `recommended` -- the `value` of the recommended option, or `nil`.
    * `allow_free_text` -- whether the author may answer with free text instead of
      picking an option (default `false`).
  """

  alias Kazi.Authoring.Clarify.Option

  @type t :: %__MODULE__{
          id: String.t(),
          prompt: String.t(),
          options: [Option.t()],
          recommended: String.t() | nil,
          allow_free_text: boolean()
        }

  @enforce_keys [:id, :prompt]
  defstruct id: nil, prompt: nil, options: [], recommended: nil, allow_free_text: false

  @doc """
  Builds a question from its `id` and `prompt`.

  Opts: `:options` (a list of `Kazi.Authoring.Clarify.Option`, default `[]`),
  `:recommended` (the recommended option's value, default `nil`), and
  `:allow_free_text` (default `false`).

      iex> q = Kazi.Authoring.Clarify.Question.new("scope", "What is in scope?")
      iex> {q.id, q.options, q.allow_free_text}
      {"scope", [], false}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(id, prompt, opts \\ []) when is_binary(id) and is_binary(prompt) and is_list(opts) do
    %__MODULE__{
      id: id,
      prompt: prompt,
      options: Keyword.get(opts, :options, []),
      recommended: Keyword.get(opts, :recommended),
      allow_free_text: Keyword.get(opts, :allow_free_text, false)
    }
  end
end
