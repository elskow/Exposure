defmodule ExposureWeb.PlaceController do
  use ExposureWeb, :controller

  def index(conn, %{"country" => country, "location" => location, "name" => name}) do
    case Exposure.get_place_by_slugs(country, location, name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_root_layout(false)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")

      place ->
        photos =
          place.photos
          |> Enum.sort_by(& &1.photo_num)
          |> Enum.map(fn ph ->
            %{
              num: ph.photo_num,
              slug: ph.slug,
              file_name: ph.file_name,
              is_favorite: ph.is_favorite
            }
          end)

        place_detail = %{
          id: place.id,
          country_slug: place.country_slug,
          location_slug: place.location_slug,
          name_slug: place.name_slug,
          name: place.name,
          location: place.location,
          country: place.country,
          total_photos: length(place.photos),
          favorites: place.favorites,
          trip_dates: Exposure.trip_dates_display(place.start_date, place.end_date),
          photos: photos
        }

        render(conn, :index, place: place_detail)
    end
  end

  def detail(conn, %{
        "country" => country,
        "location" => location,
        "name" => name,
        "photo" => photo_slug
      }) do
    case Exposure.get_place_by_slugs(country, location, name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_root_layout(false)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")

      place ->
        sorted_photos = Enum.sort_by(place.photos, & &1.photo_num)
        current_photo = Enum.find(sorted_photos, fn p -> p.slug == photo_slug end)

        case current_photo do
          nil ->
            conn
            |> put_status(:not_found)
            |> put_root_layout(false)
            |> put_view(html: ExposureWeb.ErrorHTML)
            |> render(:"404")

          photo ->
            total_photos = length(sorted_photos)

            prev_photo =
              if photo.photo_num > 1 do
                Enum.find(sorted_photos, fn p -> p.photo_num == photo.photo_num - 1 end)
              else
                nil
              end

            next_photo =
              if photo.photo_num < total_photos do
                Enum.find(sorted_photos, fn p -> p.photo_num == photo.photo_num + 1 end)
              else
                nil
              end

            unique_id = "PH/#{Integer.to_string(photo.photo_num * 12345, 16)}"

            photo_view = %{
              place_id: place.id,
              country_slug: place.country_slug,
              location_slug: place.location_slug,
              name_slug: place.name_slug,
              photo_num: photo.photo_num,
              photo_slug: photo.slug,
              file_name: photo.file_name,
              width: photo.width,
              height: photo.height,
              total_photos: total_photos,
              place_name: place.name,
              location: place.location,
              country: place.country,
              trip_dates: Exposure.trip_dates_display(place.start_date, place.end_date),
              unique_id: unique_id,
              prev_photo: prev_photo && prev_photo.photo_num,
              next_photo: next_photo && next_photo.photo_num,
              prev_photo_slug: prev_photo && prev_photo.slug,
              next_photo_slug: next_photo && next_photo.slug,
              prev_photo_file_name: prev_photo && prev_photo.file_name,
              next_photo_file_name: next_photo && next_photo.file_name
            }

            conn
            |> put_root_layout(false)
            |> render(:detail, photo: photo_view)
        end
    end
  end
end
