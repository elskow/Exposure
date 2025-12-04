# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :exposure,
  ecto_repos: [Exposure.Repo],
  generators: [timestamp_type: :utc_datetime]

# Site configuration for SEO
config :exposure, :site,
  name: "Exposure",
  description: "A curated collection of travel photography"

# Authentication configuration
# In development, uses a single default admin.
# In production, configure via ADMIN_USERS environment variable.
# See runtime.exs for production configuration.
#
# Format for multiple admins (list of maps):
#   [%{username: "admin", password: "secret"}, %{username: "editor", password: "secret2"}]
config :exposure, :admin_users, [
  %{username: "admin", password: "changeme_in_production"}
]

# File upload configuration
config :exposure, :file_upload,
  max_file_size_mb: 10,
  max_files_per_upload: 50,
  allowed_extensions: [".jpg", ".jpeg", ".png", ".webp"],
  allowed_mime_types: ["image/jpeg", "image/png", "image/webp"],
  validate_magic_numbers: true,
  validate_image_dimensions: true,
  max_image_width: 10_000,
  max_image_height: 10_000,
  max_image_pixels: 50_000_000

# Malware scanning configuration (optional - requires ClamAV)
config :exposure, :malware_scanning,
  enabled: false,
  clamav: %{
    server: "localhost",
    port: 3310
  },
  timeout_seconds: 30,
  max_file_size_for_scan_mb: 25

# Orphan file cleanup configuration
# Periodically removes files on disk without corresponding database records
config :exposure, :orphan_cleanup,
  enabled: true,
  interval_hours: 6,
  file_age_minutes: 30,
  dry_run: false

# Oban job queue configuration
# Uses SQLite Lite engine for background job processing
config :exposure, Oban,
  engine: Oban.Engines.Lite,
  repo: Exposure.Repo,
  queues: [thumbnails: 2],
  plugins: [
    # Prune completed/cancelled/discarded jobs after 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

# Configure the endpoint
config :exposure, ExposureWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ExposureWeb.ErrorHTML, json: ExposureWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Exposure.PubSub,
  live_view: [signing_salt: "IU31I1tH"],
  # Bandit HTTP server options for security
  http: [
    # HTTP/1.1 specific options (where header limits live)
    http_1_options: [
      # Max header length (default: 64KB, we set 32KB for security)
      max_header_length: 32_768,
      # Max request line length (default: 8KB)
      max_request_line_length: 8_192,
      # Max number of headers (default: 100)
      max_header_count: 100
    ],
    # General HTTP options
    http_options: [
      # Disable noisy default protocol error logs (we handle via telemetry)
      log_protocol_errors: false
    ]
  ]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :exposure, Exposure.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  exposure: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  exposure: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :trace_id, :event, :place_id, :photo_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
