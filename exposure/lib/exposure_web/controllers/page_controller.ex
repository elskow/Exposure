defmodule ExposureWeb.PageController do
  use ExposureWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
