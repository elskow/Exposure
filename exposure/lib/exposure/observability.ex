defmodule Exposure.Observability do
  @moduledoc """
  Centralized observability module for structured logging, telemetry, and tracing.

  Provides consistent logging patterns with automatic trace ID propagation,
  structured metadata, telemetry events, and integration with Datadog APM.

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
  alias Exposure.Tracer
  require Tracer

  @type metadata :: keyword()
  @type event :: String.t()

  # =============================================================================
  # Trace ID Management
  # =============================================================================

  @doc """
  Gets the current trace ID from Datadog context, Logger metadata, or generates a new one.

  Priority:
  1. Datadog distributed trace ID (if in a span)
  2. Logger metadata trace_id (for background jobs)
  3. Generate new trace ID (fallback)
  """
  @spec current_trace_id() :: String.t()
  def current_trace_id do
    case datadog_trace_id() do
      nil ->
        case Logger.metadata()[:trace_id] do
          nil -> generate_trace_id()
          id -> id
        end

      dd_trace_id ->
        dd_trace_id
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
  Gets the Datadog distributed trace ID if available.
  Returns nil if not in a Datadog span.
  """
  @spec datadog_trace_id() :: String.t() | nil
  def datadog_trace_id do
    case Tracer.current_trace_id() do
      {:ok, trace_id} when is_integer(trace_id) ->
        Integer.to_string(trace_id, 16) |> String.downcase()

      _ ->
        nil
    end
  end

  @doc """
  Executes a function with a trace ID set in Logger metadata.
  Useful for background jobs that need trace correlation.
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
  Executes a function within a Datadog trace span.
  Use for background jobs that should appear as separate traces.

  This function properly handles the trace lifecycle for Oban jobs by:
  1. Starting a fresh trace (not a child span)
  2. Cleaning up any existing trace context first
  3. Properly finishing the trace when done

  ## Example

      Observability.with_transaction("Oban", "ThumbnailWorker", trace_id, fn ->
        # work here
      end)
  """
  @spec with_transaction(String.t(), String.t(), String.t() | nil, (-> result)) :: result
        when result: any()
  def with_transaction(category, name, trace_id, fun) do
    resource = "#{category}/#{name}"

    # For Oban jobs, we need to start a fresh trace, not continue an existing one.
    # First, ensure no stale trace context exists in this process.
    # Spandex stores trace context in the process dictionary.
    # We use start_trace which creates a new root trace.
    case Tracer.start_trace(resource, service: :exposure, resource: resource) do
      {:ok, _trace} ->
        Tracer.update_span(tags: [category: category, job_name: name])

        try do
          with_trace_id(trace_id, fun)
        after
          Tracer.finish_trace()
        end

      {:error, :trace_running} ->
        # A trace is already running (shouldn't happen for Oban jobs, but handle it)
        # Just run the function within the existing trace context
        Tracer.update_span(tags: [category: category, job_name: name])
        with_trace_id(trace_id, fun)

      {:error, reason} ->
        # If tracing fails to start, still run the function
        warning("trace.start.failed", category: category, name: name, reason: inspect(reason))
        with_trace_id(trace_id, fun)
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
    add_span_tags(event, metadata)
  end

  @doc """
  Logs at warning level with structured metadata.
  Use for recoverable issues, validation failures, missing resources.
  """
  @spec warning(event(), metadata()) :: :ok
  def warning(event, metadata \\ []) do
    Logger.warning(fn -> format_message(event, metadata) end, build_metadata(event, metadata))
    add_span_tags(event, metadata)
  end

  @doc """
  Logs at error level with structured metadata.
  Use for failures requiring attention.
  """
  @spec error(event(), metadata()) :: :ok
  def error(event, metadata \\ []) do
    Logger.error(fn -> format_message(event, metadata) end, build_metadata(event, metadata))
    add_span_tags(event, metadata)
  end

  @doc """
  Logs an exception with full stacktrace at error level.
  Also marks the current span as error in Datadog.
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

    # Mark the span as error in Datadog
    Tracer.span_error(exception, stacktrace)

    # Add error context as span tags
    error_tags =
      metadata
      |> Keyword.take([:place_id, :photo_id, :photo_num, :count, :duration_ms, :attempt])
      |> Keyword.put(:event, event)
      |> Keyword.put(:error_class, inspect(exception.__struct__))

    Tracer.update_span(tags: error_tags)
  end

  @doc """
  Measures execution time of a function, logs it, emits telemetry, and adds span tags.
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

    # Create a span for this operation
    Tracer.trace event, service: :exposure, resource: event do
      Tracer.update_span(tags: [operation: event])
      start = System.monotonic_time(:microsecond)

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
          end

          reraise e, __STACKTRACE__
      end
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
  Reports a custom metric to Datadog via telemetry.
  Use for business metrics that should be tracked.

  ## Example

      report_custom_event("PhotoUpload", %{
        place_id: 1,
        count: 5,
        total_size_mb: 12.5
      })
  """
  @spec report_custom_event(String.t(), map()) :: :ok
  def report_custom_event(event_type, attributes) do
    # Emit as telemetry event - can be picked up by Datadog StatsD integration
    event_atom = event_type |> String.downcase() |> String.to_atom()
    emit(event_atom, attributes, %{event_type: event_type})
    :ok
  end

  @doc """
  Records a custom metric via telemetry.
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
    metric_atom = name |> String.replace("/", "_") |> String.downcase() |> String.to_atom()
    emit(metric_atom, %{value: value}, %{metric_name: name})
    :ok
  end

  @doc """
  Increment a counter metric.
  Useful for tracking counts of events.

  ## Example

      increment_metric("PhotoUploads", 5)
  """
  @spec increment_metric(String.t(), integer()) :: :ok
  def increment_metric(name, count \\ 1) when is_integer(count) do
    record_metric(name, count)
  end

  @doc """
  Wraps an external HTTP call and traces it in Datadog.
  Use when making HTTP requests to external services.

  ## Example

      trace_external_call("api.example.com", "GET", fn ->
        Req.get!("https://api.example.com/data")
      end)
  """
  @spec trace_external_call(String.t(), String.t(), (-> result)) :: result when result: any()
  def trace_external_call(host, method, fun) do
    resource = "#{method} #{host}"

    Tracer.trace resource, service: :external, resource: resource, type: :http do
      Tracer.update_span(
        tags: [
          "http.host": host,
          "http.method": method,
          "span.kind": "client"
        ]
      )

      try do
        result = fun.()
        result
      rescue
        e ->
          Tracer.span_error(e, __STACKTRACE__)
          reraise e, __STACKTRACE__
      end
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

    # Add Datadog trace correlation
    dd_metadata =
      case {Tracer.current_trace_id(), Tracer.current_span_id()} do
        {{:ok, trace_id}, {:ok, span_id}} ->
          [dd: [trace_id: trace_id, span_id: span_id]]

        _ ->
          []
      end

    # Add numeric values as separate metadata for indexing
    numeric_keys = [:place_id, :photo_id, :photo_num, :count, :duration_ms, :attempt, :size]

    numeric_metadata =
      Enum.filter(metadata, fn {k, _v} -> k in numeric_keys end)

    base ++ dd_metadata ++ numeric_metadata
  end

  # Adds tags to the current Datadog span
  defp add_span_tags(event, metadata) do
    tags =
      metadata
      |> Keyword.take([:place_id, :photo_id, :photo_num, :count, :duration_ms])
      |> Keyword.put(:event, event)

    if tags != [event: event] do
      Tracer.update_span(tags: tags)
    end

    :ok
  end
end
