defmodule OrchidWeb.PasswordController do
  use Phoenix.Controller, formats: [:html]

  plug(:put_view, OrchidWeb.PasswordHTML)

  def login(conn, _params) do
    case Orchid.Object.get_fact_value("site_password") do
      nil ->
        redirect(conn, to: "/setup-password")

      _password ->
        render(conn, :login, error: nil)
    end
  end

  def verify(conn, %{"password" => password}) do
    stored_hash = Orchid.Object.get_fact_value("site_password")
    input_hash = hash_password(password)

    if stored_hash == input_hash do
      conn
      |> put_session(:authenticated, true)
      |> redirect(to: "/")
    else
      render(conn, :login, error: "Incorrect password")
    end
  end

  def setup(conn, _params) do
    case Orchid.Object.get_fact_value("site_password") do
      nil ->
        render(conn, :setup, error: nil)

      _password ->
        redirect(conn, to: "/login")
    end
  end

  def create_password(conn, %{"password" => password, "password_confirmation" => confirmation}) do
    if Orchid.Object.get_fact_value("site_password") != nil do
      redirect(conn, to: "/login")
    else
      if password == "" do
        render(conn, :setup, error: "Password cannot be empty")
      else
        if password != confirmation do
          render(conn, :setup, error: "Passwords do not match")
        else
          hashed = hash_password(password)
          Orchid.Object.create(:fact, "site_password", hashed)

          conn
          |> put_session(:authenticated, true)
          |> redirect(to: "/")
        end
      end
    end
  end

  defp hash_password(password) do
    :crypto.hash(:sha256, password) |> Base.encode64()
  end
end
