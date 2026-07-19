defmodule KaziWeb.ConnCase do
  @moduledoc """
  ExUnit case template for tests that exercise the dashboard endpoint (T3.6a).

  Brings in `Phoenix.ConnTest` (and the LiveView test helpers) plus a fresh
  `%Plug.Conn{}` and the verified-route helpers, and checks out the read-model
  Sandbox so endpoint/LiveView tests stay isolated like the rest of the suite.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint KaziWeb.Endpoint

      use KaziWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup tags do
    # Share the read-model Sandbox the same way the rest of the suite does, so a
    # LiveView that later reads `Kazi.ReadModel` sees the test's transaction.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Kazi.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
