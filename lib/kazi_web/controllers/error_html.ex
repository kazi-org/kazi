defmodule KaziWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages for the dashboard endpoint (T3.6a).

  No templates: every status renders its bare reason phrase (e.g. `Not Found`
  for 404). The dashboard is a thin projection, so styled error pages are not
  warranted; this keeps `render_errors` satisfied without an asset pipeline.
  """
  use KaziWeb, :html

  @doc "Render the status's reason phrase as the error body (e.g. `404.html`)."
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
