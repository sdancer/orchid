import Config

config :orchid, :data_dir, "tmp/test_data"

config :orchid, OrchidWeb.Endpoint,
  url: [host: "localhost", scheme: "http", port: 4002],
  http: [port: 4002],
  https: false,
  force_ssl: false,
  server: false
