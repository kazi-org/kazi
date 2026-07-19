defmodule KaziWeb do
  @moduledoc """
  The web boundary for kazi's Slice-3 operator dashboard (ADR-0011, T3.6).

  `KaziWeb` is a thin, read-mostly Phoenix LiveView projection over the
  read-model and (later) NATS presence/lease state. Per ADR-0011 it is a READ
  surface: it subscribes to and queries existing state and NEVER calls into
  `Kazi.Loop` or `Kazi.Harness.*`. The only write path a surface may trigger is
  goal authoring/approval, which goes through `Kazi.Authoring` — never a
  back-door into a running reconciliation.

  This module collects the `use KaziWeb, :controller`,
  `use KaziWeb, :live_view`, `use KaziWeb, :router`, `use KaziWeb, :html`, etc.
  conveniences so the rest of the web tree stays terse. It is the conventional
  Phoenix 1.8 "context" entry point, kept deliberately lean — no generator dump.
  """

  @doc false
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc false
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @doc false
  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  @doc false
  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.Component

      unquote(verified_routes())
    end
  end

  @doc false
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: KaziWeb.Endpoint,
        router: KaziWeb.Router
    end
  end

  @doc """
  Dispatches `use KaziWeb, which` to the matching convenience above so callers
  write `use KaziWeb, :live_view` instead of repeating the imports.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
