defmodule OrchidWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {OrchidWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", OrchidWeb do
    pipe_through(:browser)

    live("/", AgentLive, :index)
    live("/agent/:id", AgentLive, :show)
    live("/prompts", PromptsLive, :index)
  end
end
