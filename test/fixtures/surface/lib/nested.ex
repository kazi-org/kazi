defmodule Surface.Outer do
  @moduledoc "Exercises nested modules and a guarded def."

  def top(x) when is_integer(x), do: x

  defmodule Inner do
    def deep(a, b, c), do: {a, b, c}
    defp hidden(_), do: :ok
  end
end
