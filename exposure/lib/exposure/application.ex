defmodule Exposure.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Get Datadog API server options from config
    # In production, these come from runtime.exs; in dev, defaults are used
    spandex_opts =
      Application.get_env(:spandex_datadog, SpandexDatadog.ApiServer, [])
      |> Keyword.put_new(:host, "localhost")
      |> Keyword.put_new(:port, 8126)
      |> Keyword.put_new(:batch_size, 10)
      |> Keyword.put_new(:sync_threshold, 100)
      |> Keyword.put_new(:http, HTTPoison)

    # Log Datadog APM configuration at startup
    Logger.info(
      "Starting SpandexDatadog.ApiServer with host=#{spandex_opts[:host]} port=#{spandex_opts[:port]}"
    )

    children = [
      ExposureWeb.Telemetry,
      # Datadog APM API server for sending traces - must be started before Repo and Endpoint
      {SpandexDatadog.ApiServer, spandex_opts},
      Exposure.Repo,
      {DNSCluster, query: Application.get_env(:exposure, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Exposure.PubSub},
      # Task supervisor for async operations
      {Task.Supervisor, name: Exposure.TaskSupervisor},
      # Oban job queue for background processing (thumbnails, etc.)
      {Oban, Application.fetch_env!(:exposure, Oban)},
      # Rate limiter for login attempts
      Exposure.Services.RateLimiter,
      # Cache for places data
      Exposure.Services.PlacesCache,
      # Periodic cleanup of orphaned files
      Exposure.Services.OrphanCleanup,
      # Start to serve requests, typically the last entry
      ExposureWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Exposure.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Initialize persistent_term config cache
    Exposure.Services.FileValidation.init_config()

    # Install Spandex Phoenix telemetry handlers for Datadog tracing
    SpandexPhoenix.Telemetry.install()

    # Sync admin users after supervision tree is started
    sync_admin_users()

    # Ensure OG images exist (generate if missing)
    ensure_og_images()

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

  defp ensure_og_images do
    # Queue OG image generation for any missing images on startup
    # This runs async to not block startup
    Task.Supervisor.start_child(Exposure.TaskSupervisor, fn ->
      # Wait for Oban to be ready
      Process.sleep(500)

      try do
        alias Exposure.Services.{OgImageGenerator, PathValidation}
        alias Exposure.Workers.OgImageWorker

        # Generate home OG if missing
        home_og_path = OgImageGenerator.home_og_path()

        unless File.exists?(home_og_path) do
          Logger.info("Queueing home OG image generation (missing)")
          OgImageWorker.queue_home_og()
        end

        # Generate place gallery OGs for any places missing them
        alias Exposure.{Repo, Place}

        Place
        |> Repo.all()
        |> Enum.each(fn place ->
          # Use PathValidation for consistent path resolution across dev/prod
          case PathValidation.get_photo_directory(place.id) do
            {:ok, place_dir} ->
              place_og_path = Path.join(place_dir, OgImageGenerator.get_place_og_filename())

              unless File.exists?(place_og_path) do
                Logger.info("Queueing place OG image generation for place #{place.id} (missing)")
                OgImageWorker.queue_place_og(place.id)
              end

            {:error, reason} ->
              Logger.warning("Could not resolve path for place #{place.id}: #{reason}")
          end
        end)
      rescue
        e ->
          Logger.error("Failed to check OG images on startup: #{Exception.message(e)}")
      end
    end)
  end
end
