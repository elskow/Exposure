defmodule ExposureWeb.ViewHelpers do
  @moduledoc """
  View helper functions for formatting dates and displaying gallery data.
  """

  alias Exposure.Gallery.Place

  @doc """
  Formats a date string for display.
  """
  def format_date_for_display(iso_date) when is_binary(iso_date) do
    case Date.from_iso8601(iso_date) do
      {:ok, date} ->
        Calendar.strftime(date, "%d %b, %Y")

      {:error, _} ->
        iso_date
    end
  end

  def format_date_for_display(_), do: ""

  @doc """
  Generates trip dates display text.
  """
  def trip_dates_display(start_date, nil), do: format_date_for_display(start_date)
  def trip_dates_display(start_date, ""), do: format_date_for_display(start_date)

  def trip_dates_display(start_date, end_date) do
    formatted_start = format_date_for_display(start_date)
    formatted_end = format_date_for_display(end_date)

    if formatted_start == formatted_end do
      formatted_start
    else
      day_start = String.slice(formatted_start, 0, 2)
      "#{day_start}-#{formatted_end}"
    end
  end

  @doc """
  Gets the favorite photo for a place, or the first photo if none is marked as favorite.
  """
  def get_favorite_photo(%Place{photos: photos}) when is_list(photos) do
    Enum.find(photos, fn p -> p.is_favorite end) ||
      Enum.min_by(photos, & &1.photo_num, fn -> nil end)
  end

  def get_favorite_photo(_), do: nil
end
