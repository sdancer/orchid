import Config

config :orchid, OrchidWeb.Endpoint,
  url: [host: "orch.run", scheme: "https", port: 443],
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4080],
  https: [
    port: 4000,
    cipher_suite: :strong,
    certfile: "/etc/letsencrypt/live/orch.run/fullchain.pem",
    keyfile: "/etc/letsencrypt/live/orch.run/privkey.pem"
  ],
  secret_key_base: "orchid_secret_key_base_that_is_at_least_64_bytes_long_for_security",
  live_view: [signing_salt: "orchid_live_view_salt"],
  render_errors: [formats: [html: OrchidWeb.ErrorHTML], layout: false],
  pubsub_server: Orchid.PubSub,
  server: true,
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]

config :phoenix, :json_library, Jason

config :logger, level: :info

config :orchid, :data_dir, "priv/data"

config :esbuild, :version, "0.25.0"

import_config "#{config_env()}.exs"
