defmodule ExposureWeb.HomeHTML do
  @moduledoc """
  This module contains pages rendered by HomeController.
  """
  use ExposureWeb, :html

  embed_templates("home_html/*")
end
