defmodule OrchidWeb.PasswordHTML do
  use Phoenix.Component

  def login(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; justify-content: center; min-height: 100vh; background: #0d1117;">
      <div style="background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 2rem; width: 100%; max-width: 380px;">
        <h1 style="color: #58a6ff; font-size: 1.4rem; margin-bottom: 1.5rem; text-align: center; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
          Orchid
        </h1>
        <form method="post" action="/login">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <div style="margin-bottom: 1rem;">
            <input
              type="password"
              name="password"
              placeholder="Password"
              autofocus
              style="width: 100%; background: #0d1117; border: 1px solid #30363d; color: #c9d1d9; padding: 0.6rem 0.75rem; border-radius: 6px; font-size: 0.9rem; font-family: inherit;"
            />
          </div>
          <%= if @error do %>
            <div style="color: #f85149; font-size: 0.85rem; margin-bottom: 1rem;">
              {@error}
            </div>
          <% end %>
          <button
            type="submit"
            style="width: 100%; background: #238636; color: white; border: none; padding: 0.6rem 1rem; border-radius: 6px; cursor: pointer; font-size: 0.9rem; font-family: inherit;"
          >
            Sign in
          </button>
        </form>
      </div>
    </div>
    """
  end

  def setup(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; justify-content: center; min-height: 100vh; background: #0d1117;">
      <div style="background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 2rem; width: 100%; max-width: 380px;">
        <h1 style="color: #58a6ff; font-size: 1.4rem; margin-bottom: 0.5rem; text-align: center; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
          Orchid
        </h1>
        <p style="color: #8b949e; font-size: 0.85rem; text-align: center; margin-bottom: 1.5rem;">
          Set a password to protect your instance
        </p>
        <form method="post" action="/setup-password">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <div style="margin-bottom: 1rem;">
            <input
              type="password"
              name="password"
              placeholder="Password"
              autofocus
              style="width: 100%; background: #0d1117; border: 1px solid #30363d; color: #c9d1d9; padding: 0.6rem 0.75rem; border-radius: 6px; font-size: 0.9rem; font-family: inherit;"
            />
          </div>
          <div style="margin-bottom: 1rem;">
            <input
              type="password"
              name="password_confirmation"
              placeholder="Confirm password"
              style="width: 100%; background: #0d1117; border: 1px solid #30363d; color: #c9d1d9; padding: 0.6rem 0.75rem; border-radius: 6px; font-size: 0.9rem; font-family: inherit;"
            />
          </div>
          <%= if @error do %>
            <div style="color: #f85149; font-size: 0.85rem; margin-bottom: 1rem;">
              {@error}
            </div>
          <% end %>
          <button
            type="submit"
            style="width: 100%; background: #238636; color: white; border: none; padding: 0.6rem 1rem; border-radius: 6px; cursor: pointer; font-size: 0.9rem; font-family: inherit;"
          >
            Set password
          </button>
        </form>
      </div>
    </div>
    """
  end
end
