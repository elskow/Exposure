defmodule ExposureWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use ExposureWeb, :html

  # Custom error pages - embed_templates generates functions like "404"/1
  embed_templates("error_html/*")

  # Phoenix calls render("404.html", assigns), so we need to map to our embedded function
  def render("404.html", assigns) do
    # Wrap in root layout to get CSS/styling
    assigns =
      assigns
      |> Map.put(:__changed__, nil)
      |> Map.put_new(:page_title, "Not Found")

    content = __MODULE__."404"(assigns)

    ExposureWeb.Layouts.root(%{
      inner_content: content,
      page_title: "Not Found",
      conn: assigns[:conn]
    })
  end

  # Fallback for error codes that don't have custom templates
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
