defmodule KaziWeb.DashboardLive do
  @moduledoc """
  Root LiveView for the operator dashboard (ADR-0011, T3.6a).

  The skeleton renders a static shell with a stable `#dashboard` landmark the
  Playwright smoke test asserts on. T3.6b/c/d mount their panels here: the goal
  board, the presence/lease map, and the per-goal history view — each reading
  from `Kazi.ReadModel` (and, for presence/leases, an injected NATS source).
  This view holds no loop or harness references, honoring the ADR-0011 read-only
  boundary.
  """
  use KaziWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "kazi dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="dashboard">
      <h1>kazi operator dashboard</h1>
      <p>Read-only projection of the reconciler (ADR-0011). Panels arrive in T3.6b–d.</p>
      <nav>
        <.link navigate={~p"/goals"} id="nav-goal-board">Goal board</.link>
      </nav>
    </main>
    """
  end
end
