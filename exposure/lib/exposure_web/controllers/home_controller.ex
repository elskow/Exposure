defmodule ExposureWeb.HomeController do
  use ExposureWeb, :controller

  def index(conn, _params) do
    places = Exposure.list_places_with_stats()

    place_summaries =
      Enum.map(places, fn place ->
        %{
          id: place.id,
          country_slug: place.country_slug,
          location_slug: place.location_slug,
          name_slug: place.name_slug,
          name: place.name,
          location: place.location,
          country: place.country,
          photos: place.photo_count,
          trip_dates: Exposure.trip_dates_display(place.start_date, place.end_date),
          sort_order: place.sort_order,
          favorite_photo_num: place.favorite_photo_num,
          favorite_photo_file_name: place.favorite_photo_file_name
        }
      end)

    render(conn, :index, places: place_summaries)
  end
end
