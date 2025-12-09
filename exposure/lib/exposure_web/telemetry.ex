defmodule ExposureWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Attach telemetry handlers for Datadog integration
    attach_handlers()

    # Attach Bandit error handler for protocol errors (oversized headers, etc.)
    ExposureWeb.BanditLogger.attach()

    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ==========================================================================
  # Datadog Telemetry Handlers
  # ==========================================================================

  defp attach_handlers do
    # Ecto query telemetry -> log slow queries
    :telemetry.attach(
      "exposure-ecto-datadog",
      [:exposure, :repo, :query],
      &__MODULE__.handle_ecto_query/4,
      nil
    )

    # NOTE: Oban job tracing is handled directly in workers via Log.with_transaction()
    # to avoid duplicate trace conflicts. Workers have full control over their trace lifecycle.

    # Phoenix request telemetry -> Datadog span tags
    :telemetry.attach(
      "exposure-phoenix-datadog",
      [:phoenix, :router_dispatch, :stop],
      &__MODULE__.handle_phoenix_request/4,
      nil
    )

    Logger.debug("Telemetry handlers attached for Datadog integration")
  end

  @doc false
  # Handle Ecto query events - log slow queries
  def handle_ecto_query(_event, measurements, metadata, _config) do
    # Convert to milliseconds
    total_time_ms =
      System.convert_time_unit(measurements[:total_time] || 0, :native, :millisecond)

    # For slow queries (>100ms), log for analysis
    if total_time_ms > 100 do
      Logger.warning("Slow query detected",
        query: String.slice(metadata[:query] || "", 0, 500),
        total_time_ms: total_time_ms,
        source: metadata[:source]
      )
    end
  end

  @doc false
  # Handle Phoenix request completion - add route info to span
  def handle_phoenix_request(_event, measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    # Add route-specific tags to current span
    Exposure.Tracer.update_span(
      tags: [
        "phoenix.controller": inspect(metadata[:plug]),
        "phoenix.action": metadata[:plug_opts],
        "request.duration_ms": duration_ms
      ]
    )
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("exposure.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("exposure.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("exposure.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("exposure.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("exposure.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # ==========================================================================
      # Custom Business Metrics
      # ==========================================================================

      # Photo Operations
      counter("exposure.photo_upload.count",
        tags: [:place_id],
        description: "Number of photos uploaded"
      ),
      sum("exposure.photo_upload.total_count",
        description: "Total photos uploaded (sum of batch counts)"
      ),
      summary("exposure.photo_upload.duration_ms",
        tags: [:place_id],
        unit: :millisecond,
        description: "Time to process photo upload"
      ),
      counter("exposure.photo_delete.count",
        tags: [:place_id],
        description: "Number of photos deleted"
      ),

      # Thumbnail Generation
      counter("exposure.thumbnail_generate.count",
        tags: [:place_id, :status],
        description: "Thumbnail generation attempts"
      ),
      summary("exposure.thumbnail_generate.duration_ms",
        tags: [:place_id],
        unit: :millisecond,
        description: "Time to generate thumbnail"
      ),
      counter("exposure.thumbnail_generate_error.count",
        tags: [:place_id],
        description: "Failed thumbnail generations"
      ),

      # Place Operations
      counter("exposure.place_create.count",
        description: "Places created"
      ),
      counter("exposure.place_delete.count",
        description: "Places deleted"
      ),

      # Authentication
      counter("exposure.auth_login.count",
        tags: [:method, :success],
        description: "Login attempts by method and outcome"
      ),

      # Oban Jobs
      counter("exposure.oban_job.count",
        tags: [:worker, :queue, :state],
        description: "Oban job completions"
      ),
      summary("exposure.oban_job.duration_ms",
        tags: [:worker],
        unit: :millisecond,
        description: "Oban job duration"
      ),
      counter("exposure.oban_job_error.count",
        tags: [:worker, :queue],
        description: "Oban job errors"
      )
    ]
  end

  defp periodic_measurements do
    [
      # Report VM metrics periodically
      {__MODULE__, :report_vm_metrics, []}
    ]
  end

  @doc false
  def report_vm_metrics do
    # Memory metrics (in MB)
    memory = :erlang.memory()

    # Emit telemetry for local metrics
    :telemetry.execute([:vm, :memory], %{total: memory[:total]}, %{})

    # Run queue lengths (indicator of scheduler load)
    run_queue = :erlang.statistics(:run_queue)
    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: run_queue}, %{})
  end
end
