defmodule ExposureWeb.Plugs.DatadogTrace do
  @moduledoc """
  Plug that sets the Datadog span resource name based on Phoenix routing.

  This ensures traces appear with meaningful names in Datadog APM
  instead of generic path names.

  The resource name format is: "Controller#action" (e.g., "PlaceController#index")

  ## Usage

  Add to a pipeline in your router:

      pipeline :browser do
        # ... other plugs
        plug ExposureWeb.Plugs.DatadogTrace
      end

  Note: This plug complements SpandexPhoenix which handles the actual
  tracing. This plug just sets better resource names.
  """

  import Plug.Conn
  alias Exposure.Tracer

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      set_resource_name(conn)
      conn
    end)
  end

  defp set_resource_name(conn) do
    controller = conn.private[:phoenix_controller]
    action = conn.private[:phoenix_action]

    cond do
      controller && action ->
        # Format: "ControllerName#action" (Datadog convention)
        controller_name =
          controller
          |> Module.split()
          |> List.last()

        resource = "#{controller_name}##{action}"

        Tracer.update_span(
          resource: resource,
          tags: [
            "phoenix.controller": controller_name,
            "phoenix.action": action
          ]
        )

      # For non-Phoenix routes (e.g., static files handled by Plug.Static)
      conn.request_path ->
        # Group static assets to reduce cardinality
        case categorize_path(conn.request_path) do
          {:static, category} ->
            Tracer.update_span(
              resource: "Static##{category}",
              tags: ["static.category": category]
            )

          :other ->
            # Don't set a name, let it fall through to default
            :ok
        end

      true ->
        :ok
    end
  end

  # Categorize paths to reduce metric cardinality
  defp categorize_path(path) do
    cond do
      String.starts_with?(path, "/assets/") -> {:static, "assets"}
      String.starts_with?(path, "/images/") -> {:static, "images"}
      String.starts_with?(path, "/fonts/") -> {:static, "fonts"}
      String.ends_with?(path, ".js") -> {:static, "js"}
      String.ends_with?(path, ".css") -> {:static, "css"}
      String.ends_with?(path, ".ico") -> {:static, "favicon"}
      String.ends_with?(path, ".webmanifest") -> {:static, "manifest"}
      String.ends_with?(path, ".png") or String.ends_with?(path, ".jpg") -> {:static, "images"}
      true -> :other
    end
  end
end
