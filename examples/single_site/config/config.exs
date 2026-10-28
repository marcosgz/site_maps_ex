# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :single_site, SingleSite.Sitemaps, url: "http://localhost:4000/sitemap.xml"

config :single_site,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :single_site, SingleSiteWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SingleSiteWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SingleSite.PubSub,
  live_view: [signing_salt: "Y17P0oc9"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
