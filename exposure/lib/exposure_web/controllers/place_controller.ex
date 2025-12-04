defmodule ExposureWeb.PlaceController do
  use ExposureWeb, :controller
  alias ExposureWeb.ViewHelpers

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

        # Find favorite photo for OG image (absolute URL required)
        favorite_photo = Enum.find(photos, fn p -> p.is_favorite end) || List.first(photos)

        og_image =
          if favorite_photo do
            base_name = Path.rootname(favorite_photo.file_name)
            # Use OG image with text overlay if available, fallback to medium thumbnail
            ViewHelpers.absolute_url("/images/places/#{place.id}/#{base_name}-og.jpg")
          end

        canonical_url = ViewHelpers.absolute_url("/places/#{country}/#{location}/#{name}")
        home_url = ViewHelpers.absolute_url("/")

        # JSON-LD: ImageGallery + BreadcrumbList
        json_ld = [
          %{
            "@context" => "https://schema.org",
            "@type" => "ImageGallery",
            "name" => place.name,
            "description" =>
              "Photo gallery from #{place.name} in #{place.location}, #{place.country}",
            "url" => canonical_url,
            "numberOfItems" => length(photos),
            "contentLocation" => %{
              "@type" => "Place",
              "name" => place.name,
              "address" => %{
                "@type" => "PostalAddress",
                "addressLocality" => place.location,
                "addressCountry" => place.country
              }
            }
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" => [
              %{
                "@type" => "ListItem",
                "position" => 1,
                "name" => "Home",
                "item" => home_url
              },
              %{
                "@type" => "ListItem",
                "position" => 2,
                "name" => "#{place.name}",
                "item" => canonical_url
              }
            ]
          }
        ]

        conn
        |> assign(:page_title, "#{place.name} - #{place.location}, #{place.country}")
        |> assign(
          :meta_description,
          "Photo gallery from #{place.name} in #{place.location}, #{place.country}. #{length(photos)} photos from #{Exposure.trip_dates_display(place.start_date, place.end_date)}."
        )
        |> assign(:og_image, og_image)
        |> assign(:og_image_width, 1200)
        |> assign(:og_image_height, 630)
        |> assign(:canonical_url, canonical_url)
        |> assign(:json_ld, json_ld)
        |> render(:index, place: place_detail)
    end
  end

  def detail(conn, %{
        "country" => country,
        "location" => location,
        "name" => name,
        "photo" => photo_slug
      }) do
    # First get the place without preloading all photos
    case Exposure.get_place_by_slugs_without_photos(country, location, name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_root_layout(false)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")

      place ->
        # Get only the current photo and its neighbors (3 photos max instead of all)
        case Exposure.get_photo_with_neighbors(place.id, photo_slug) do
          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> put_root_layout(false)
            |> put_view(html: ExposureWeb.ErrorHTML)
            |> render(:"404")

          {:ok, %{photo: photo, prev: prev_photo, next: next_photo, total: total_photos}} ->
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

            # OG image for photo detail (use OG image with text overlay)
            base_name = Path.rootname(photo.file_name)

            og_image =
              ViewHelpers.absolute_url("/images/places/#{place.id}/#{base_name}-og.jpg")

            full_image_url =
              ViewHelpers.absolute_url("/images/places/#{place.id}/#{photo.file_name}")

            canonical_url =
              ViewHelpers.absolute_url("/places/#{country}/#{location}/#{name}/#{photo_slug}")

            gallery_url = ViewHelpers.absolute_url("/places/#{country}/#{location}/#{name}")
            home_url = ViewHelpers.absolute_url("/")

            # OG image dimensions are fixed at 1200x630
            og_width = 1200
            og_height = 630

            # JSON-LD: ImageObject + BreadcrumbList
            json_ld = [
              %{
                "@context" => "https://schema.org",
                "@type" => "ImageObject",
                "name" => "Photo #{photo.photo_num} - #{place.name}",
                "description" =>
                  "Photo #{photo.photo_num} of #{total_photos} from #{place.name} in #{place.location}, #{place.country}",
                "contentUrl" => full_image_url,
                "thumbnailUrl" => og_image,
                "url" => canonical_url,
                "width" => photo.width,
                "height" => photo.height,
                "isPartOf" => %{
                  "@type" => "ImageGallery",
                  "name" => place.name,
                  "url" => gallery_url
                },
                "contentLocation" => %{
                  "@type" => "Place",
                  "name" => place.name,
                  "address" => %{
                    "@type" => "PostalAddress",
                    "addressLocality" => place.location,
                    "addressCountry" => place.country
                  }
                }
              },
              %{
                "@context" => "https://schema.org",
                "@type" => "BreadcrumbList",
                "itemListElement" => [
                  %{
                    "@type" => "ListItem",
                    "position" => 1,
                    "name" => "Home",
                    "item" => home_url
                  },
                  %{
                    "@type" => "ListItem",
                    "position" => 2,
                    "name" => "#{place.name}",
                    "item" => gallery_url
                  },
                  %{
                    "@type" => "ListItem",
                    "position" => 3,
                    "name" => "Photo #{photo.photo_num}",
                    "item" => canonical_url
                  }
                ]
              }
            ]

            conn
            |> assign(:page_title, "Photo #{photo.photo_num} - #{place.name}, #{place.location}")
            |> assign(
              :meta_description,
              "Photo #{photo.photo_num} of #{total_photos} from #{place.name} in #{place.location}, #{place.country}."
            )
            |> assign(:og_image, og_image)
            |> assign(:og_image_width, og_width)
            |> assign(:og_image_height, og_height)
            |> assign(:og_type, "article")
            |> assign(:canonical_url, canonical_url)
            |> assign(:json_ld, json_ld)
            |> render(:detail, photo: photo_view)
        end
    end
  end

end
