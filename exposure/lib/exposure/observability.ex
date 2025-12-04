defmodule Exposure.Observability do
  @moduledoc """
  Centralized observability module for structured logging, telemetry, and tracing.

  Provides consistent logging patterns with automatic trace ID propagation,
  structured metadata, telemetry events, and integration with New Relic APM.

  ## Usage

      alias Exposure.Observability, as: Log

      # Simple logging with context
      Log.info("photo.upload.success", place_id: 1, count: 5)

      # With trace ID propagation for background jobs
      Log.with_trace_id(trace_id, fn ->
        Log.info("thumbnail.generate.start", photo_id: 123)
      end)

      # Emit telemetry event for metrics
      Log.emit(:photo_upload, %{count: 5}, %{place_id: 1})

  ## Log Levels

  - `debug` - Detailed tracing, cache operations, internal state
  - `info` - Successful operations, significant events
  - `warning` - Recoverable issues, validation failures, missing resources
  - `error` - Failures requiring attention, external service errors

  ## Telemetry Events

  All telemetry events are emitted under the `[:exposure, <event_name>]` prefix:

  - `[:exposure, :photo_upload]` - Photo upload completed
  - `[:exposure, :photo_delete]` - Photo deleted
  - `[:exposure, :thumbnail_generate]` - Thumbnail generation completed
  - `[:exposure, :place_create]` - Place created
  - `[:exposure, :place_delete]` - Place deleted
  """

  require Logger

  @type metadata :: keyword()
  @type event :: String.t()

  # =============================================================================
  # Trace ID Management
  # =============================================================================

  @doc """
  Gets the current trace ID from New Relic context, Logger metadata, or generates a new one.

  Priority:
  1. New Relic distributed trace ID (if in a transaction)
  2. Logger metadata trace_id (for background jobs)
  3. Generate new trace ID (fallback)
  """
  @spec current_trace_id() :: String.t()
  def current_trace_id do
    case new_relic_trace_id() do
      nil ->
        case Logger.metadata()[:trace_id] do
          nil -> generate_trace_id()
          id -> id
        end

      nr_trace_id ->
        nr_trace_id
    end
  end

  @doc """
  Generates a new trace ID (16-character hex string).
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @doc """
  Gets the New Relic distributed trace ID if available.
  Returns nil if not in a New Relic transaction.
  """
  @spec new_relic_trace_id() :: String.t() | nil
  def new_relic_trace_id do
    case NewRelic.DistributedTrace.get_tracing_context() do
      %{trace_id: trace_id} when is_binary(trace_id) -> trace_id
      _ -> nil
    end
  end

  @doc """
  Executes a function with a trace ID set in Logger metadata.
  Useful for background jobs that need trace correlation.

  Also starts a New Relic "Other" transaction if headers are provided.
  """
  @spec with_trace_id(String.t() | nil, (-> result)) :: result when result: any()
  def with_trace_id(nil, fun), do: with_trace_id(generate_trace_id(), fun)

  def with_trace_id(trace_id, fun) when is_binary(trace_id) do
    previous_trace_id = Logger.metadata()[:trace_id]
    Logger.metadata(trace_id: trace_id)

    try do
      fun.()
    after
      Logger.metadata(trace_id: previous_trace_id)
    end
  end

  @doc """
  Executes a function within a New Relic "Other" transaction.
  Use for background jobs that should appear as separate transactions.

  ## Example

      Observability.with_transaction("Oban", "ThumbnailWorker", trace_id, fn ->
        # work here
      end)
  """
  @spec with_transaction(String.t(), String.t(), String.t() | nil, (-> result)) :: result
        when result: any()
  def with_transaction(category, name, trace_id, fun) do
    headers =
      if trace_id do
        # Create W3C traceparent header for distributed trace continuity
        %{
          "traceparent" => "00-#{String.pad_leading(trace_id, 32, "0")}-#{generate_trace_id()}-01"
        }
      else
        %{}
      end

    NewRelic.start_transaction(category, name, headers)

    try do
      with_trace_id(trace_id, fun)
    after
      NewRelic.stop_transaction()
    end
  end

  # =============================================================================
  # Logging Functions
  # =============================================================================

  @doc """
  Logs at debug level with structured metadata.
  Use for detailed tracing, cache operations, and internal state.
  """
  @spec debug(event(), metadata()) :: :ok
  def debug(event, metadata \\ []) do
    Logger.debug(fn -> format_message(event, metadata) end, build_metadata(event, metadata))
  end

  @doc """
  Logs at info level with structured metadata.
  Use for successful operations and significant events.
  """
  @spec info(event(), metadata()) :: :ok
  def info(event, metadata \\ []) do
    Logger.info(fn -> format_message(event, metadata) end, build_metadata(event, metadata))
    add_nr_attributes(event, metadata)
  end

  @doc """
  Logs at warning level with structured metadata.
  Use for recoverable issues, validation failures, missing resources.
  """
  @spec warning(event(), metadata()) :: :ok
  def warning(event, metadata \\ []) do
    Logger.warning(fn -> format_message(event, metadata) end, build_metadata(event, metadata))
    add_nr_attributes(event, metadata)
  end

  @doc """
  Logs at error level with structured metadata.
  Use for failures requiring attention.
  """
  @spec error(event(), metadata()) :: :ok
  def error(event, metadata \\ []) do
    Logger.error(fn -> format_message(event, metadata) end, build_metadata(event, metadata))
    add_nr_attributes(event, metadata)
  end

  @doc """
  Logs an exception with full stacktrace at error level.
  Also reports the error to New Relic with full context.
  """
  @spec exception(event(), Exception.t(), Exception.stacktrace(), metadata()) :: :ok
  def exception(event, exception, stacktrace, metadata \\ []) do
    error_metadata =
      metadata
      |> Keyword.put(:exception, Exception.format(:error, exception, stacktrace))
      |> Keyword.put(:error_type, exception.__struct__)

    Logger.error(
      fn -> format_message(event, error_metadata) end,
      build_metadata(event, error_metadata)
    )

    # Add error context as transaction attributes before reporting
    error_attrs =
      metadata
      |> Keyword.take([:place_id, :photo_id, :photo_num, :count, :duration_ms, :attempt])
      |> Keyword.put(:event, event)
      |> Keyword.put(:error_class, inspect(exception.__struct__))

    NewRelic.add_attributes(error_attrs)

    # Report to New Relic for error tracking
    NewRelic.notice_error(exception, stacktrace)
  end

  @doc """
  Measures execution time of a function, logs it, emits telemetry, and adds span attributes.
  Returns the function result.

  ## Options

  - `:telemetry_event` - Atom for telemetry event name (emits `[:exposure, <name>]`)

  ## Example

      measure("photo.resize", [photo_id: 123, telemetry_event: :photo_resize], fn ->
        # expensive operation
      end)
  """
  @spec measure(event(), metadata() | keyword(), (-> result)) :: result when result: any()
  def measure(event, metadata \\ [], fun) do
    {opts, metadata} = Keyword.split(metadata, [:telemetry_event])
    telemetry_event = Keyword.get(opts, :telemetry_event)
    start = System.monotonic_time(:microsecond)

    # Add span attributes for this operation
    NewRelic.add_attributes(operation: event)

    try do
      result = fun.()
      duration_us = System.monotonic_time(:microsecond) - start
      duration_ms = Float.round(duration_us / 1000, 2)

      info(
        "#{event}.completed",
        Keyword.merge(metadata, duration_ms: duration_ms)
      )

      if telemetry_event do
        emit(telemetry_event, %{duration_ms: duration_ms}, Map.new(metadata))
        # Also report as New Relic custom metric for dashboards
        record_metric("#{telemetry_event}/Duration", duration_ms)
      end

      result
    rescue
      e ->
        duration_us = System.monotonic_time(:microsecond) - start
        duration_ms = Float.round(duration_us / 1000, 2)

        exception(
          "#{event}.failed",
          e,
          __STACKTRACE__,
          Keyword.merge(metadata, duration_ms: duration_ms)
        )

        if telemetry_event do
          emit(:"#{telemetry_event}_error", %{duration_ms: duration_ms}, Map.new(metadata))
          NewRelic.increment_custom_metric("#{telemetry_event}/Error")
        end

        reraise e, __STACKTRACE__
    end
  end

  # =============================================================================
  # Telemetry Functions
  # =============================================================================

  @doc """
  Emits a telemetry event under the `[:exposure, <event_name>]` prefix.

  ## Parameters

  - `event_name` - Atom identifying the event (e.g., `:photo_upload`)
  - `measurements` - Map of numeric measurements (e.g., `%{count: 5, duration_ms: 123.4}`)
  - `metadata` - Map of contextual data (e.g., `%{place_id: 1, photo_id: 2}`)

  ## Example

      emit(:photo_upload, %{count: 5, size_bytes: 1024000}, %{place_id: 1})
      emit(:thumbnail_generate, %{duration_ms: 456.7}, %{photo_id: 123, place_id: 1})
  """
  @spec emit(atom(), map(), map()) :: :ok
  def emit(event_name, measurements, metadata \\ %{}) do
    :telemetry.execute(
      [:exposure, event_name],
      measurements,
      Map.put(metadata, :timestamp, System.system_time(:millisecond))
    )
  end

  @doc """
  Reports a custom event to New Relic Insights.
  Use for business metrics that should be queryable in NRQL.

  ## Example

      report_custom_event("PhotoUpload", %{
        place_id: 1,
        count: 5,
        total_size_mb: 12.5
      })
  """
  @spec report_custom_event(String.t(), map()) :: :ok
  def report_custom_event(event_type, attributes) do
    NewRelic.report_custom_event(event_type, attributes)
    :ok
  end

  @doc """
  Records a custom metric to New Relic for dashboards and alerting.
  Use for numeric measurements that should be aggregated over time.

  ## Parameters

  - `name` - Metric name
  - `value` - Numeric value to record

  ## Example

      record_metric("PhotoUpload/Duration", 123.45)
      record_metric("ThumbnailGeneration/Count", 1)
  """
  @spec record_metric(String.t(), number()) :: :ok
  def record_metric(name, value) when is_number(value) do
    NewRelic.report_custom_metric(name, value)
    :ok
  end

  @doc """
  Increment a counter metric in New Relic.
  Useful for tracking counts of events.

  ## Example

      increment_metric("PhotoUploads", 5)
  """
  @spec increment_metric(String.t(), integer()) :: :ok
  def increment_metric(name, count \\ 1) when is_integer(count) do
    NewRelic.increment_custom_metric(name, count)
    :ok
  end

  @doc """
  Wraps an external HTTP call and adds attributes for New Relic tracing.
  Use when making HTTP requests to external services.

  ## Example

      trace_external_call("api.example.com", "GET", fn ->
        Req.get!("https://api.example.com/data")
      end)
  """
  @spec trace_external_call(String.t(), String.t(), (-> result)) :: result when result: any()
  def trace_external_call(host, method, fun) do
    start = System.monotonic_time(:microsecond)
    NewRelic.add_attributes(external_host: host, external_method: method)

    try do
      result = fun.()
      duration_us = System.monotonic_time(:microsecond) - start
      duration_ms = Float.round(duration_us / 1000, 2)

      # Report external call metric
      NewRelic.report_custom_metric("External/#{host}/#{method}", duration_ms)
      result
    rescue
      e ->
        NewRelic.add_attributes(external_error: true)
        reraise e, __STACKTRACE__
    end
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  # Formats the log message in a consistent pattern
  defp format_message(event, metadata) do
    context =
      metadata
      |> Keyword.drop([:exception, :error_type])
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

    if context == "" do
      event
    else
      "#{event} #{context}"
    end
  end

  # Builds Logger metadata with the event name for structured logging
  defp build_metadata(event, metadata) do
    base = [event: event]

    # Add numeric values as separate metadata for indexing
    numeric_keys = [:place_id, :photo_id, :photo_num, :count, :duration_ms, :attempt, :size]

    numeric_metadata =
      Enum.filter(metadata, fn {k, _v} -> k in numeric_keys end)

    base ++ numeric_metadata
  end

  # Adds attributes to the current New Relic transaction
  defp add_nr_attributes(event, metadata) do
    attrs =
      metadata
      |> Keyword.take([:place_id, :photo_id, :photo_num, :count, :duration_ms])
      |> Keyword.put(:event, event)

    if attrs != [event: event] do
      NewRelic.add_attributes(attrs)
    end

    :ok
  end
end
