defmodule OrchidWeb.Plugs.PasswordGate do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.request_path in ["/login", "/setup-password"] do
      conn
    else
      if get_session(conn, :authenticated) do
        conn
      else
        case Orchid.Object.get_fact_value("site_password") do
          nil ->
            conn |> redirect(to: "/setup-password") |> halt()

          _password ->
            conn |> redirect(to: "/login") |> halt()
        end
      end
    end
  end
end
