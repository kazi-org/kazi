defmodule KaziWeb.Layouts do
  @moduledoc """
  Root layout for the operator dashboard (T3.6a).

  Kept inline and asset-free on purpose: the skeleton has no esbuild/tailwind
  bundle, so the document references no external CSS/JS. The LiveView JS that
  would upgrade the page to a live socket is added when a live surface needs it
  (T3.6b onward); the server-rendered HTML stands alone for the smoke test.
  """
  use KaziWeb, :html

  @doc "The outer HTML document wrapping every page."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>kazi · operator dashboard</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
