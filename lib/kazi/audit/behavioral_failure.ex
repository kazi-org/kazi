defmodule Kazi.Audit.BehavioralFailure do
  @moduledoc "Separates explicit assertion evidence from an ambiguous process failure."
  # Command providers' exit-only failures include syntax/build errors. Structured
  # JSON comparisons on a successful checker process establish an observed value.
  # Other providers own their fail/error distinction through PredicateResult.
  def supported?(%{status: :fail, evidence: %{exit: exit} = evidence}) do
    exit == 0 and evidence[:verdict] == "json" and is_number(evidence[:observed])
  end

  def supported?(%{status: :fail}), do: true
  def supported?(_), do: false
end
