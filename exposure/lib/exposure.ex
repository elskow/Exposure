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
  Uses optimized queries instead of preloading all photos.
  """
  def list_places_with_stats do
    # Main query with photo count
    places_with_counts =
      from(p in Place,
        left_join: ph in Photo,
        on: ph.place_id == p.id,
        group_by: p.id,
        order_by: [asc: p.sort_order, desc: p.inserted_at],
        select: {p, count(ph.id)}
      )
      |> Repo.all()

    # Get favorite photos in one query
    place_ids = Enum.map(places_with_counts, fn {place, _} -> place.id end)

    favorite_photos =
      from(ph in Photo,
        where: ph.place_id in ^place_ids and ph.is_favorite == true,
        select: {ph.place_id, %{photo_num: ph.photo_num, file_name: ph.file_name}}
      )
      |> Repo.all()
      |> Map.new()

    # Get first photos as fallback (for places without a favorite)
    # SQLite doesn't support DISTINCT ON, so we use a subquery to get min photo_num per place
    first_photo_nums =
      from(ph in Photo,
        where: ph.place_id in ^place_ids,
        group_by: ph.place_id,
        select: {ph.place_id, min(ph.photo_num)}
      )
      |> Repo.all()
      |> Map.new()

    first_photos =
      if map_size(first_photo_nums) > 0 do
        # Build conditions to fetch the actual photo records
        conditions =
          Enum.map(first_photo_nums, fn {place_id, photo_num} ->
            dynamic([ph], ph.place_id == ^place_id and ph.photo_num == ^photo_num)
          end)
          |> Enum.reduce(fn cond, acc -> dynamic([ph], ^acc or ^cond) end)

        from(ph in Photo,
          where: ^conditions,
          select: {ph.place_id, %{photo_num: ph.photo_num, file_name: ph.file_name}}
        )
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

    # Combine results
    Enum.map(places_with_counts, fn {place, photo_count} ->
      favorite = Map.get(favorite_photos, place.id) || Map.get(first_photos, place.id)

      %{
        id: place.id,
        country_slug: place.country_slug,
        location_slug: place.location_slug,
        name_slug: place.name_slug,
        name: place.name,
        location: place.location,
        country: place.country,
        start_date: place.start_date,
        end_date: place.end_date,
        sort_order: place.sort_order,
        photo_count: photo_count,
        favorite_photo_num: favorite && favorite.photo_num,
        favorite_photo_file_name: favorite && favorite.file_name
      }
    end)
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
    |> preload(:photos)
    |> Repo.one()
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
end
