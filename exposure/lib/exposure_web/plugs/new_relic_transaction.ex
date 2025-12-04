defmodule ExposureWeb.Plugs.NewRelicTransaction do
  @moduledoc """
  Plug that sets the New Relic transaction name based on Phoenix routing.

  This ensures transactions appear with meaningful names in New Relic APM
  instead of "Unknown".

  The transaction name format is: "Controller/action" (e.g., "PlaceController/index")

  ## Usage

  Add to a pipeline in your router:

      pipeline :browser do
        # ... other plugs
        plug ExposureWeb.Plugs.NewRelicTransaction
      end
  """

  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      set_transaction_name(conn)
      conn
    end)
  end

  defp set_transaction_name(conn) do
    controller = conn.private[:phoenix_controller]
    action = conn.private[:phoenix_action]

    cond do
      controller && action ->
        # Format: "ControllerName/action"
        controller_name =
          controller
          |> Module.split()
          |> List.last()

        NewRelic.set_transaction_name("#{controller_name}/#{action}")

      # For non-Phoenix routes (e.g., static files handled by Plug.Static)
      conn.request_path ->
        # Group static assets to reduce cardinality
        case categorize_path(conn.request_path) do
          {:static, category} ->
            NewRelic.set_transaction_name("Static/#{category}")

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
