defmodule ExposureWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Attach telemetry handlers for New Relic integration
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
  # New Relic Telemetry Handlers
  # ==========================================================================

  defp attach_handlers do
    # Ecto query telemetry -> New Relic
    :telemetry.attach(
      "exposure-ecto-new-relic",
      [:exposure, :repo, :query],
      &__MODULE__.handle_ecto_query/4,
      nil
    )

    # Oban job telemetry -> New Relic
    :telemetry.attach_many(
      "exposure-oban-new-relic",
      [
        [:oban, :job, :start],
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &__MODULE__.handle_oban_event/4,
      nil
    )

    # Phoenix request telemetry -> New Relic custom attributes
    :telemetry.attach(
      "exposure-phoenix-new-relic",
      [:phoenix, :router_dispatch, :stop],
      &__MODULE__.handle_phoenix_request/4,
      nil
    )

    Logger.debug("Telemetry handlers attached for New Relic integration")
  end

  @doc false
  # Handle Ecto query events - report slow queries to New Relic
  def handle_ecto_query(_event, measurements, metadata, _config) do
    # Convert to milliseconds
    total_time_ms =
      System.convert_time_unit(measurements[:total_time] || 0, :native, :millisecond)

    query_time_ms =
      System.convert_time_unit(measurements[:query_time] || 0, :native, :millisecond)

    queue_time_ms =
      System.convert_time_unit(measurements[:queue_time] || 0, :native, :millisecond)

    # Report as custom metric for aggregate monitoring
    NewRelic.report_custom_metric("Datastore/SQLite/all", total_time_ms)

    # For slow queries (>100ms), add custom event for analysis
    if total_time_ms > 100 do
      NewRelic.report_custom_event("SlowQuery", %{
        query: String.slice(metadata[:query] || "", 0, 500),
        total_time_ms: total_time_ms,
        query_time_ms: query_time_ms,
        queue_time_ms: queue_time_ms,
        source: metadata[:source]
      })
    end
  end

  @doc false
  # Handle Oban job events
  def handle_oban_event([:oban, :job, :start], _measurements, metadata, _config) do
    # Add job info as transaction attributes
    NewRelic.add_attributes(
      oban_worker: metadata.job.worker,
      oban_queue: metadata.job.queue,
      oban_attempt: metadata.job.attempt
    )
  end

  def handle_oban_event([:oban, :job, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    queue_time_ms =
      System.convert_time_unit(measurements[:queue_time] || 0, :native, :millisecond)

    # Report job completion metrics
    NewRelic.report_custom_metric("Oban/#{metadata.job.worker}/Duration", duration_ms)
    NewRelic.report_custom_metric("Oban/#{metadata.job.worker}/QueueTime", queue_time_ms)

    # Report custom event for job analytics
    NewRelic.report_custom_event("ObanJob", %{
      worker: metadata.job.worker,
      queue: to_string(metadata.job.queue),
      state: to_string(metadata.state),
      attempt: metadata.job.attempt,
      duration_ms: duration_ms,
      queue_time_ms: queue_time_ms
    })
  end

  def handle_oban_event([:oban, :job, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    # Report job failure metrics
    NewRelic.increment_custom_metric("Oban/#{metadata.job.worker}/Error")

    # Report error event
    NewRelic.report_custom_event("ObanJobError", %{
      worker: metadata.job.worker,
      queue: to_string(metadata.job.queue),
      attempt: metadata.job.attempt,
      max_attempts: metadata.job.max_attempts,
      duration_ms: duration_ms,
      error_kind: to_string(metadata[:kind]),
      error_reason: inspect(metadata[:reason]) |> String.slice(0, 500)
    })
  end

  @doc false
  # Handle Phoenix request completion - add route info
  def handle_phoenix_request(_event, measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    # Add route-specific attributes to current transaction
    NewRelic.add_attributes(
      phoenix_controller: inspect(metadata[:plug]),
      phoenix_action: metadata[:plug_opts],
      request_duration_ms: duration_ms
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
      )
    ]
  end

  defp periodic_measurements do
    [
      # Report VM metrics to New Relic periodically
      {__MODULE__, :report_vm_metrics, []}
    ]
  end

  @doc false
  def report_vm_metrics do
    # Name this background task so it doesn't appear as "Unknown" in New Relic
    NewRelic.set_transaction_name("Background/TelemetryPoller/report_vm_metrics")

    # Memory metrics (in MB)
    memory = :erlang.memory()
    total_mb = trunc(memory[:total] / 1_048_576)
    processes_mb = trunc(memory[:processes] / 1_048_576)
    binary_mb = trunc(memory[:binary] / 1_048_576)
    ets_mb = trunc(memory[:ets] / 1_048_576)

    NewRelic.report_custom_metric("VM/Memory/Total", total_mb)
    NewRelic.report_custom_metric("VM/Memory/Processes", processes_mb)
    NewRelic.report_custom_metric("VM/Memory/Binary", binary_mb)
    NewRelic.report_custom_metric("VM/Memory/ETS", ets_mb)

    # Process metrics
    process_count = :erlang.system_info(:process_count)
    NewRelic.report_custom_metric("VM/Processes/Count", process_count)

    # Run queue lengths (indicator of scheduler load)
    run_queue = :erlang.statistics(:run_queue)
    NewRelic.report_custom_metric("VM/RunQueue/Total", run_queue)

    # Emit telemetry for local metrics
    :telemetry.execute([:vm, :memory], %{total: memory[:total]}, %{})
    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: run_queue}, %{})
  end
end
