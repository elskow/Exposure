defmodule ExposureWeb.BanditLogger do
  @moduledoc """
  Custom telemetry handler for Bandit HTTP server errors.

  Handles protocol errors (like oversized headers) gracefully by:
  - Logging them as warnings instead of errors (since they're usually bots/attacks)
  - Emitting telemetry events for monitoring
  - Providing structured logging with relevant context

  ## Common Errors Handled

  - "Header too long" - Oversized headers (likely attack/bot)
  - "Request line too long" - Oversized request URI
  - "Too many headers" - Excessive number of headers
  - Connection timeouts and closures
  """

  alias Exposure.Observability, as: Log

  @doc """
  Attaches the Bandit error telemetry handler.
  Should be called during application startup.
  """
  def attach do
    :telemetry.attach(
      "exposure-bandit-errors",
      [:bandit, :request, :stop],
      &__MODULE__.handle_request_stop/4,
      nil
    )

    :telemetry.attach(
      "exposure-bandit-exceptions",
      [:bandit, :request, :exception],
      &__MODULE__.handle_request_exception/4,
      nil
    )
  end

  @doc false
  def handle_request_stop(_event, _measurements, %{error: error} = _metadata, _config)
      when not is_nil(error) do
    handle_error(error)
  end

  def handle_request_stop(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  def handle_request_exception(_event, _measurements, metadata, _config) do
    error = metadata[:exception] || metadata[:kind]
    handle_error(error)
  end

  defp handle_error(error) do
    error_message = extract_error_message(error)
    error_type = categorize_error(error_message)

    # Log as warning since these are typically malicious/bot requests
    Log.warning("http.protocol_error",
      error_type: error_type,
      error_message: String.slice(error_message, 0, 200),
      category: "security"
    )

    # Emit telemetry for monitoring attack patterns
    :telemetry.execute(
      [:exposure, :http_protocol_error],
      %{count: 1},
      %{error_type: error_type}
    )
  end

  defp extract_error_message(%{message: message}) when is_binary(message), do: message
  defp extract_error_message(%Bandit.HTTPError{message: message}), do: message
  defp extract_error_message(error) when is_exception(error), do: Exception.message(error)
  defp extract_error_message(error) when is_atom(error), do: to_string(error)
  defp extract_error_message(error), do: inspect(error)

  defp categorize_error(message) do
    message_lower = String.downcase(message)

    cond do
      String.contains?(message_lower, "header too long") -> "header_too_long"
      String.contains?(message_lower, "request line too long") -> "request_line_too_long"
      String.contains?(message_lower, "too many headers") -> "too_many_headers"
      String.contains?(message_lower, "timeout") -> "timeout"
      String.contains?(message_lower, "closed") -> "connection_closed"
      String.contains?(message_lower, "request_uri_too_long") -> "uri_too_long"
      String.contains?(message_lower, "bad request") -> "bad_request"
      true -> "other"
    end
  end
end
