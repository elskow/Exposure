defmodule Exposure.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExposureWeb.Telemetry,
      Exposure.Repo,
      {DNSCluster, query: Application.get_env(:exposure, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Exposure.PubSub},
      # Rate limiter for login attempts
      Exposure.Services.RateLimiter,
      # Start to serve requests, typically the last entry
      ExposureWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Exposure.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Sync admin users after supervision tree is started
    sync_admin_users()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExposureWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp sync_admin_users do
    # Run in a separate process to not block startup
    Task.start(fn ->
      # Small delay to ensure Repo is fully ready
      Process.sleep(100)
      Exposure.Services.AdminSync.sync()
    end)
  end
end
