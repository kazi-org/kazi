defmodule Surface.Calc do
  @moduledoc "A tiny fixture module with a public and a private function."

  def add(a, b), do: a + b

  def zero, do: 0

  defp internal(x), do: x * 2

  def double(x), do: internal(x)
end
