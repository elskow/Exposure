defmodule Exposure.Gallery do
  @moduledoc """
  The Gallery context for managing places and photos.
  """

  import Ecto.Query, warn: false
  alias Exposure.Repo
  alias Exposure.Gallery.Place
  alias Exposure.Services.SlugGenerator

  # =============================================================================
  # Places
  # =============================================================================

  @doc """
  Returns all places ordered by sort_order and created_at.
  """
  def list_places do
    Place
    |> order_by([p], asc: p.sort_order, desc: p.inserted_at)
    |> preload(:photos)
    |> Repo.all()
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
  Uses a single batch UPDATE with CASE statement for efficiency.
  """
  def reorder_places(ordered_ids) when is_list(ordered_ids) do
    if ordered_ids == [] do
      {:ok, :no_changes}
    else
      # Build CASE statement for batch update
      case_clauses =
        ordered_ids
        |> Enum.with_index()
        |> Enum.map(fn {id, order} -> "WHEN #{id} THEN #{order}" end)
        |> Enum.join(" ")

      ids_list = Enum.join(ordered_ids, ", ")

      sql = """
      UPDATE places
      SET sort_order = CASE id #{case_clauses} END,
          updated_at = NOW()
      WHERE id IN (#{ids_list})
      """

      case Repo.query(sql, []) do
        {:ok, _result} -> {:ok, :reordered}
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
  # Slug Generation
  # =============================================================================

  @slug_chars ~c"abcdefghijklmnopqrstuvwxyz0123456789"
  @slug_length 8

  @doc """
  Generates a unique slug using the provided exists function.
  """
  def generate_unique_slug(exists_fn, attempts \\ 0) do
    if attempts > 100 do
      raise "Failed to generate unique slug after 100 attempts"
    end

    slug = generate_random_slug()

    if exists_fn.(slug) do
      generate_unique_slug(exists_fn, attempts + 1)
    else
      slug
    end
  end

  defp generate_random_slug do
    for _ <- 1..@slug_length, into: "" do
      <<Enum.random(@slug_chars)>>
    end
  end

  # =============================================================================
  # View Helpers
  # =============================================================================

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
