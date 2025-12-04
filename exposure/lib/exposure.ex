defmodule Exposure do
  @moduledoc """
  The Exposure context for managing places and photos.
  """

  import Ecto.Query, warn: false
  alias Exposure.Repo
  alias Exposure.{Place, Photo}
  alias Exposure.Services.SlugGenerator
  alias ExposureWeb.ViewHelpers

  # =============================================================================
  # Places
  # =============================================================================

  @doc """
  Returns all places ordered by sort_order and created_at.
  Includes preloaded photos - use list_places_with_stats for lightweight listing.
  """
  def list_places do
    Place
    |> order_by([p], asc: p.sort_order, desc: p.inserted_at)
    |> preload(:photos)
    |> Repo.all()
  end

  @doc """
  Returns all places with photo count and favorite photo info.
  Uses ETS cache for improved performance (5 minute TTL).
  """
  def list_places_with_stats do
    Exposure.Services.PlacesCache.get_places_with_stats()
  end

  @doc """
  Returns all places with photo count and favorite photo info (uncached).
  Optimized to use a single query with subqueries for cover photos.
  This is called by PlacesCache - do not call directly unless you need fresh data.
  """
  def list_places_with_stats_uncached do
    # Single query that gets places with counts and cover photo info using subqueries
    # This replaces 3-4 separate queries with just 1 database round-trip
    sql = """
    SELECT
      p.id,
      p.country_slug,
      p.location_slug,
      p.name_slug,
      p.name,
      p.location,
      p.country,
      p.start_date,
      p.end_date,
      p.sort_order,
      p.favorites,
      (SELECT COUNT(*) FROM photos ph WHERE ph.place_id = p.id) as photo_count,
      COALESCE(
        (SELECT ph.photo_num FROM photos ph WHERE ph.place_id = p.id AND ph.is_favorite = 1 LIMIT 1),
        (SELECT ph.photo_num FROM photos ph WHERE ph.place_id = p.id ORDER BY ph.photo_num LIMIT 1)
      ) as cover_photo_num,
      COALESCE(
        (SELECT ph.file_name FROM photos ph WHERE ph.place_id = p.id AND ph.is_favorite = 1 LIMIT 1),
        (SELECT ph.file_name FROM photos ph WHERE ph.place_id = p.id ORDER BY ph.photo_num LIMIT 1)
      ) as cover_photo_file_name
    FROM places p
    ORDER BY p.sort_order ASC, p.inserted_at DESC
    """

    case Repo.query(sql, []) do
      {:ok, %{rows: rows, columns: columns}} ->
        columns = Enum.map(columns, &String.to_atom/1)

        Enum.map(rows, fn row ->
          data = Enum.zip(columns, row) |> Map.new()

          %{
            id: data.id,
            country_slug: data.country_slug,
            location_slug: data.location_slug,
            name_slug: data.name_slug,
            name: data.name,
            location: data.location,
            country: data.country,
            start_date: data.start_date,
            end_date: data.end_date,
            sort_order: data.sort_order,
            favorites: data.favorites,
            photo_count: data.photo_count || 0,
            favorite_photo_num: data.cover_photo_num,
            favorite_photo_file_name: data.cover_photo_file_name
          }
        end)

      {:error, reason} ->
        require Logger
        Logger.error("Failed to fetch places with stats: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Invalidates the places cache.
  Call this after modifying places or photos.
  """
  def invalidate_places_cache do
    Exposure.Services.PlacesCache.invalidate_places()
  end

  @doc """
  Gets a single place by id.
  """
  def get_place(id), do: Repo.get(Place, id) |> Repo.preload(:photos)

  @doc """
  Gets a single place by hierarchical slugs (country, location, name).
  """
  def get_place_by_slugs(country_slug, location_slug, name_slug) do
    Place
    |> where(
      [p],
      p.country_slug == ^country_slug and p.location_slug == ^location_slug and
        p.name_slug == ^name_slug
    )
    |> preload([p], photos: ^from(ph in Photo, order_by: ph.photo_num))
    |> Repo.one()
  end

  @doc """
  Gets a single place by hierarchical slugs without preloading photos.
  Use this when you only need place metadata.
  """
  def get_place_by_slugs_without_photos(country_slug, location_slug, name_slug) do
    Place
    |> where(
      [p],
      p.country_slug == ^country_slug and p.location_slug == ^location_slug and
        p.name_slug == ^name_slug
    )
    |> Repo.one()
  end

  @doc """
  Gets a photo by place_id and slug, along with its prev/next neighbors.
  Returns {:ok, %{photo: photo, prev: prev_photo, next: next_photo, total: count}} or {:error, :not_found}
  This is optimized to query only 3 photos + count instead of all photos.
  """
  def get_photo_with_neighbors(place_id, photo_slug) do
    # Get the current photo by slug
    current_photo =
      Photo
      |> where([p], p.place_id == ^place_id and p.slug == ^photo_slug)
      |> Repo.one()

    case current_photo do
      nil ->
        {:error, :not_found}

      photo ->
        # Get prev and next photos in a single query
        neighbors =
          Photo
          |> where([p], p.place_id == ^place_id)
          |> where(
            [p],
            p.photo_num == ^(photo.photo_num - 1) or p.photo_num == ^(photo.photo_num + 1)
          )
          |> Repo.all()

        prev_photo = Enum.find(neighbors, &(&1.photo_num == photo.photo_num - 1))
        next_photo = Enum.find(neighbors, &(&1.photo_num == photo.photo_num + 1))

        # Get total count
        total =
          Photo
          |> where([p], p.place_id == ^place_id)
          |> Repo.aggregate(:count)

        {:ok, %{photo: photo, prev: prev_photo, next: next_photo, total: total}}
    end
  end

  @doc """
  Creates a place with unique hierarchical slugs.
  """
  def create_place(attrs \\ %{}) do
    max_sort_order =
      Place
      |> select([p], max(p.sort_order))
      |> Repo.one() || -1

    # Generate slugs from country, location, and name
    country = Map.get(attrs, :country) || Map.get(attrs, "country") || ""
    location = Map.get(attrs, :location) || Map.get(attrs, "location") || ""
    name = Map.get(attrs, :name) || Map.get(attrs, "name") || ""

    country_slug = SlugGenerator.generate(country)
    location_slug = SlugGenerator.generate(location)

    # For name_slug, we need to check uniqueness within country+location
    name_slug =
      SlugGenerator.generate_unique(name, fn slug ->
        slugs_exist?(country_slug, location_slug, slug)
      end)

    attrs =
      attrs
      |> Map.put(:country_slug, country_slug)
      |> Map.put(:location_slug, location_slug)
      |> Map.put(:name_slug, name_slug)
      |> Map.put(:sort_order, max_sort_order + 1)

    %Place{}
    |> Place.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a place.
  """
  def update_place(%Place{} = place, attrs) do
    place
    |> Place.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a place.
  """
  def delete_place(%Place{} = place) do
    Repo.delete(place)
  end

  @doc """
  Returns the total favorites count across all places.
  """
  def total_favorites do
    Place
    |> select([p], sum(p.favorites))
    |> Repo.one() || 0
  end

  @doc """
  Reorders places by the given list of ids.
  Uses a single bulk UPDATE with CASE statement for efficiency.
  """
  def reorder_places(ordered_ids) when is_list(ordered_ids) do
    if ordered_ids == [] do
      {:ok, :no_changes}
    else
      # Validate all IDs are integers to prevent injection
      validated_ids =
        Enum.map(ordered_ids, fn id ->
          if is_integer(id), do: id, else: String.to_integer(id)
        end)

      now = DateTime.utc_now()

      # Build CASE clause for bulk update: CASE id WHEN 1 THEN 0 WHEN 2 THEN 1 ... END
      {case_fragments, params} =
        validated_ids
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {id, order}, {fragments, params} ->
          {["WHEN ? THEN ?" | fragments], [order, id | params]}
        end)

      case_sql = "CASE id #{Enum.join(Enum.reverse(case_fragments), " ")} END"

      # Build the full query with placeholders
      id_placeholders = Enum.map_join(1..length(validated_ids), ", ", fn _ -> "?" end)

      sql = """
      UPDATE places
      SET sort_order = #{case_sql},
          updated_at = ?
      WHERE id IN (#{id_placeholders})
      """

      # Parameters: [case params (reversed)..., now, ids...]
      all_params = Enum.reverse(params) ++ [now | validated_ids]

      case Repo.query(sql, all_params) do
        {:ok, _} -> {:ok, :reordered}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp slugs_exist?(country_slug, location_slug, name_slug) do
    Place
    |> where(
      [p],
      p.country_slug == ^country_slug and p.location_slug == ^location_slug and
        p.name_slug == ^name_slug
    )
    |> Repo.exists?()
  end

  # =============================================================================
  # View Helpers (delegated to ExposureWeb.ViewHelpers for backward compatibility)
  # =============================================================================

  defdelegate format_date_for_display(iso_date), to: ViewHelpers
  defdelegate trip_dates_display(start_date, end_date), to: ViewHelpers
  defdelegate get_favorite_photo(place), to: ViewHelpers

  # =============================================================================
  # Sitemap
  # =============================================================================

  @doc """
  Returns all places with their photo data for sitemap generation.
  Includes updated_at timestamps for lastmod and file_name for image sitemap.
  """
  def list_places_with_photos_for_sitemap do
    Place
    |> order_by([p], asc: p.sort_order, desc: p.inserted_at)
    |> preload([p],
      photos:
        ^from(ph in Photo,
          select: %{
            slug: ph.slug,
            file_name: ph.file_name,
            updated_at: ph.updated_at
          },
          order_by: ph.photo_num
        )
    )
    |> Repo.all()
    |> Enum.map(fn place ->
      %{
        id: place.id,
        country_slug: place.country_slug,
        location_slug: place.location_slug,
        name_slug: place.name_slug,
        name: place.name,
        location: place.location,
        country: place.country,
        updated_at: place.updated_at,
        photos: place.photos
      }
    end)
  end
end
