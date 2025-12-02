import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/exposure start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :exposure, ExposureWeb.Endpoint, server: true
end

config :exposure, ExposureWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# =============================================================================
# Authentication Configuration
# =============================================================================
# AUTH_MODE can be: "local", "oidc", or "both" (default: "local")
# - local: username/password authentication only
# - oidc: OIDC/SSO authentication only
# - both: both methods available
auth_mode = System.get_env("AUTH_MODE", "local")

config :exposure, :auth,
  mode: auth_mode,
  local_enabled: auth_mode in ["local", "both"],
  oidc_enabled: auth_mode in ["oidc", "both"]

# =============================================================================
# Local Authentication (Admin Users)
# =============================================================================
# Format: "username1:password1,username2:password2"
# Example: ADMIN_USERS="admin:secretpass,editor:editorpass"
if admin_users_env = System.get_env("ADMIN_USERS") do
  admin_users =
    admin_users_env
    |> String.split(",", trim: true)
    |> Enum.map(fn user_str ->
      case String.split(user_str, ":", parts: 2) do
        [username, password] when username != "" and password != "" ->
          %{username: String.trim(username), password: String.trim(password)}

        _ ->
          raise """
          Invalid ADMIN_USERS format: #{user_str}
          Expected format: "username:password"
          """
      end
    end)

  if admin_users == [] do
    raise "ADMIN_USERS is set but contains no valid users"
  end

  config :exposure, :admin_users, admin_users
end

# =============================================================================
# OIDC Configuration
# =============================================================================
# Required when AUTH_MODE is "oidc" or "both":
#   OIDC_CLIENT_ID - Client ID from your OIDC provider
#   OIDC_CLIENT_SECRET - Client secret from your OIDC provider
#   OIDC_ISSUER_URL - Issuer URL (used for discovery) OR set endpoints manually:
#     OIDC_AUTHORIZATION_ENDPOINT - Authorization endpoint URL
#     OIDC_TOKEN_ENDPOINT - Token endpoint URL
#     OIDC_USERINFO_ENDPOINT - UserInfo endpoint URL (optional)
#
# Optional:
#   OIDC_PROVIDER_NAME - Display name for the SSO button (default: "SSO")
#   OIDC_SCOPE - OAuth scopes (default: "openid email profile")
#   OIDC_ALLOWED_EMAILS - Comma-separated list of allowed emails
#   OIDC_ALLOWED_DOMAINS - Comma-separated list of allowed email domains
#
# Examples:
#   # Google
#   OIDC_ISSUER_URL=https://accounts.google.com
#   OIDC_CLIENT_ID=your-client-id.apps.googleusercontent.com
#   OIDC_CLIENT_SECRET=your-secret
#   OIDC_ALLOWED_DOMAINS=yourcompany.com
#
#   # Keycloak
#   OIDC_ISSUER_URL=https://keycloak.example.com/realms/your-realm
#   OIDC_CLIENT_ID=exposure
#   OIDC_CLIENT_SECRET=your-secret

if auth_mode in ["oidc", "both"] do
  oidc_client_id = System.get_env("OIDC_CLIENT_ID")
  oidc_client_secret = System.get_env("OIDC_CLIENT_SECRET")

  if is_nil(oidc_client_id) or is_nil(oidc_client_secret) do
    raise """
    OIDC authentication is enabled but missing required configuration.

    Required environment variables:
      OIDC_CLIENT_ID - Your OIDC client ID
      OIDC_CLIENT_SECRET - Your OIDC client secret

    And either:
      OIDC_ISSUER_URL - For auto-discovery of endpoints

    Or manually set:
      OIDC_AUTHORIZATION_ENDPOINT
      OIDC_TOKEN_ENDPOINT
    """
  end

  # Build redirect URI from host
  host = System.get_env("PHX_HOST", "localhost:4000")
  scheme = if config_env() == :prod, do: "https", else: "http"
  redirect_uri = System.get_env("OIDC_REDIRECT_URI", "#{scheme}://#{host}/admin/auth/callback")

  # Try to use discovery URL or manual endpoints
  issuer_url = System.get_env("OIDC_ISSUER_URL")

  {auth_endpoint, token_endpoint, userinfo_endpoint} =
    if issuer_url do
      # Common OIDC discovery endpoints
      base = String.trim_trailing(issuer_url, "/")

      {
        System.get_env("OIDC_AUTHORIZATION_ENDPOINT", "#{base}/protocol/openid-connect/auth"),
        System.get_env("OIDC_TOKEN_ENDPOINT", "#{base}/protocol/openid-connect/token"),
        System.get_env("OIDC_USERINFO_ENDPOINT", "#{base}/protocol/openid-connect/userinfo")
      }
    else
      {
        System.get_env("OIDC_AUTHORIZATION_ENDPOINT"),
        System.get_env("OIDC_TOKEN_ENDPOINT"),
        System.get_env("OIDC_USERINFO_ENDPOINT")
      }
    end

  # Parse allowed emails and domains
  allowed_emails =
    case System.get_env("OIDC_ALLOWED_EMAILS") do
      nil -> []
      "" -> []
      emails -> String.split(emails, ",", trim: true) |> Enum.map(&String.trim/1)
    end

  allowed_domains =
    case System.get_env("OIDC_ALLOWED_DOMAINS") do
      nil -> []
      "" -> []
      domains -> String.split(domains, ",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :exposure, :oidc,
    enabled: true,
    provider_name: System.get_env("OIDC_PROVIDER_NAME", "SSO"),
    client_id: oidc_client_id,
    client_secret: oidc_client_secret,
    redirect_uri: redirect_uri,
    authorization_endpoint: auth_endpoint,
    token_endpoint: token_endpoint,
    userinfo_endpoint: userinfo_endpoint,
    scope: System.get_env("OIDC_SCOPE", "openid email profile"),
    allowed_emails: allowed_emails,
    allowed_domains: allowed_domains
end

# In production, require admin users if local auth is enabled
if config_env() == :prod do
  local_auth_enabled = auth_mode in ["local", "both"]

  if local_auth_enabled and is_nil(System.get_env("ADMIN_USERS")) do
    raise """
    Environment variable ADMIN_USERS is missing.
    Please configure at least one admin user for local authentication.

    Format: "username:password" or "user1:pass1,user2:pass2" for multiple admins

    Example:
      export ADMIN_USERS="admin:your-secure-password-here"

    Or set AUTH_MODE=oidc to disable local authentication.
    """
  end
end

# Malware scanning configuration from environment variables
if System.get_env("MALWARE_SCANNING_ENABLED") == "true" do
  config :exposure, :malware_scanning,
    enabled: true,
    clamav: %{
      server: System.get_env("CLAMAV_SERVER") || "localhost",
      port: String.to_integer(System.get_env("CLAMAV_PORT") || "3310")
    },
    timeout_seconds: String.to_integer(System.get_env("CLAMAV_TIMEOUT") || "30"),
    max_file_size_for_scan_mb:
      String.to_integer(System.get_env("CLAMAV_MAX_FILE_SIZE_MB") || "25")
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /app/data/exposure.db
      """

  config :exposure, Exposure.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :exposure, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :exposure, ExposureWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :exposure, ExposureWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :exposure, ExposureWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :exposure, Exposure.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
