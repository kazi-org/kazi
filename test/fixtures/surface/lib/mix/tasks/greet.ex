defmodule Mix.Tasks.Surface.Greet do
  @moduledoc "A fixture Mix task: `mix surface.greet`."
  use Mix.Task

  @impl Mix.Task
  def run(_args), do: Mix.shell().info("hello")
end
