defmodule Exposure.Tracer do
  @moduledoc """
  Datadog APM Tracer configuration.

  This module configures Spandex for distributed tracing with Datadog.
  All traces are sent to the Datadog Agent which forwards them to Datadog APM.

  ## Configuration

  The tracer is configured via environment variables:

  - `DD_AGENT_HOST` - Datadog Agent host (default: "localhost")
  - `DD_TRACE_AGENT_PORT` - Datadog Agent trace port (default: 8126)
  - `DD_SERVICE` - Service name (default: "exposure")
  - `DD_ENV` - Environment name (default: "production")

  ## Usage

  The tracer is automatically started by the application and integrates with:
  - Phoenix requests via SpandexPhoenix
  - Ecto queries via SpandexEcto
  - Custom spans via Exposure.Observability

  For manual tracing:

      Exposure.Tracer.trace("my_operation", service: :exposure) do
        # your code here
      end
  """

  use Spandex.Tracer, otp_app: :exposure
end
