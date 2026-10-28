import Config

config :two_tenants, sitemaps_dir: Path.expand("../tmp/test_sitemaps", __DIR__)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :two_tenants, TwoTenantsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xg18q0y8ghaaqwYX4ljiZJpzz+Os21wC24lo/oJ/s8/8UN7Qii7jj1cJnt+4wCpx",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
