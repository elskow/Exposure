defmodule ExposureWeb.Plugs.TraceId do
  @moduledoc """
  Plug that adds trace ID to requests for distributed tracing.

  - Reads trace ID from incoming `x-trace-id` header (for distributed tracing)
  - Falls back to request_id if no trace header present
  - Generates a new trace ID if neither exists
  - Adds trace ID to Logger metadata and response headers
  - Compatible with New Relic distributed tracing

  ## Usage in endpoint.ex

      plug ExposureWeb.Plugs.TraceId
  """

  import Plug.Conn
  require Logger

  @trace_header "x-trace-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    trace_id = get_or_generate_trace_id(conn)

    # Add to Logger metadata for all subsequent logs in this request
    Logger.metadata(trace_id: trace_id)

    # Store in conn assigns for access in controllers/views
    conn
    |> assign(:trace_id, trace_id)
    |> put_resp_header(@trace_header, trace_id)
  end

  defp get_or_generate_trace_id(conn) do
    # Priority: incoming trace header > request_id > generate new
    case get_req_header(conn, @trace_header) do
      [trace_id | _] when byte_size(trace_id) > 0 ->
        trace_id

      _ ->
        # Fall back to request_id if available, otherwise generate
        case Logger.metadata()[:request_id] do
          nil -> Exposure.Observability.generate_trace_id()
          request_id -> request_id
        end
    end
  end
end
