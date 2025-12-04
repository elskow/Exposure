defmodule ExposureWeb.SitemapController do
  use ExposureWeb, :controller

  @doc """
  Generates a dynamic sitemap.xml for SEO.
  Includes all public pages: home, place galleries, and individual photos.
  Follows the sitemap protocol with lastmod dates and image extensions.
  """
  def sitemap(conn, _params) do
    base_url = get_base_url(conn)
    places = Exposure.list_places_with_photos_for_sitemap()

    sitemap = build_sitemap(base_url, places)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, sitemap)
  end

  @doc """
  Generates a dynamic robots.txt with sitemap URL.
  """
  def robots(conn, _params) do
    base_url = get_base_url(conn)

    robots = """
    # Exposure Photo Gallery
    # https://github.com/your-repo/exposure

    User-agent: *
    Allow: /

    # Block admin area from all crawlers
    Disallow: /admin
    Disallow: /admin/
    Disallow: /dev/

    # Block Phoenix internal paths
    Disallow: /phoenix/

    # Sitemap
    Sitemap: #{base_url}/sitemap.xml
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, robots)
  end

  defp get_base_url(conn) do
    # In production, prefer the configured host
    case Application.get_env(:exposure, ExposureWeb.Endpoint)[:url] do
      [host: host, port: 443, scheme: "https"] ->
        "https://#{host}"

      [host: host] when host != "localhost" ->
        "https://#{host}"

      _ ->
        # Fall back to conn info for dev
        scheme = if conn.scheme == :https, do: "https", else: "http"
        host = conn.host
        port = conn.port

        if (scheme == "https" and port == 443) or (scheme == "http" and port == 80) do
          "#{scheme}://#{host}"
        else
          "#{scheme}://#{host}:#{port}"
        end
    end
  end

  defp build_sitemap(base_url, places) do
    # Find the most recent update across all places for home page lastmod
    latest_update =
      places
      |> Enum.map(& &1.updated_at)
      |> Enum.max(DateTime, fn -> DateTime.utc_now() end)
      |> format_lastmod()

    urls = [
      # Home page - highest priority
      url_entry(base_url, "/", "1.0", "daily", latest_update, [])
    ]

    # Add place pages and their photos
    place_urls =
      Enum.flat_map(places, fn place ->
        place_path = "/places/#{place.country_slug}/#{place.location_slug}/#{place.name_slug}"
        place_lastmod = format_lastmod(place.updated_at)

        # Collect all images for this place (for image sitemap extension)
        place_images =
          Enum.map(place.photos, fn photo ->
            %{
              loc: "#{base_url}/images/places/#{place.id}/#{photo.file_name}",
              title: "#{place.name}, #{place.location}",
              caption: "Photo from #{place.name}, #{place.location}, #{place.country}"
            }
          end)

        # Place gallery page with images
        place_entry = url_entry(base_url, place_path, "0.8", "weekly", place_lastmod, place_images)

        # Individual photo pages
        photo_entries =
          Enum.map(place.photos, fn photo ->
            photo_path = "#{place_path}/#{photo.slug}"
            photo_lastmod = format_lastmod(photo.updated_at)

            # Single image for photo page
            photo_image = [
              %{
                loc: "#{base_url}/images/places/#{place.id}/#{photo.file_name}",
                title: "#{place.name}, #{place.location}",
                caption: "Photo from #{place.name}, #{place.location}, #{place.country}"
              }
            ]

            url_entry(base_url, photo_path, "0.6", "monthly", photo_lastmod, photo_image)
          end)

        [place_entry | photo_entries]
      end)

    all_urls = urls ++ place_urls

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
            xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
    #{Enum.join(all_urls, "\n")}
    </urlset>
    """
  end

  defp url_entry(base_url, path, priority, changefreq, lastmod, images) do
    image_tags =
      images
      |> Enum.map(fn img ->
        """
            <image:image>
              <image:loc>#{escape_xml(img.loc)}</image:loc>
              <image:title>#{escape_xml(img.title)}</image:title>
              <image:caption>#{escape_xml(img.caption)}</image:caption>
            </image:image>
        """
      end)
      |> Enum.join("")

    """
      <url>
        <loc>#{base_url}#{path}</loc>
        <lastmod>#{lastmod}</lastmod>
        <changefreq>#{changefreq}</changefreq>
        <priority>#{priority}</priority>
    #{image_tags}  </url>
    """
  end

  # Format DateTime as W3C date format (YYYY-MM-DD)
  defp format_lastmod(nil), do: Date.utc_today() |> Date.to_iso8601()
  defp format_lastmod(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_iso8601()
  defp format_lastmod(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt) |> Date.to_iso8601()

  # Escape XML special characters
  defp escape_xml(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(nil), do: ""
end
