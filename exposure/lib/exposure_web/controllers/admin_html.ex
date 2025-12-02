defmodule ExposureWeb.AdminHTML do
  @moduledoc """
  This module contains pages rendered by AdminController.
  """
  use ExposureWeb, :html

  embed_templates("admin_html/*")
end
