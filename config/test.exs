import Config

config :orchid, :data_dir, "tmp/test_data"

config :orchid, OrchidWeb.Endpoint,
  http: [port: 4002],
  server: false
