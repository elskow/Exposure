defmodule Exposure.Gallery do
  @moduledoc """
  The Gallery context for managing places and photos.
  """

  import Ecto.Query, warn: false
  alias Exposure.Repo
  alias Exposure.Gallery.Place
  alias Exposure.Services.SlugGenerator
  alias ExposureWeb.ViewHelpers

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
  Uses Ecto's update_all for safe parameterized queries.
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

      Repo.transaction(fn ->
        validated_ids
        |> Enum.with_index()
        |> Enum.each(fn {id, order} ->
          Place
          |> where([p], p.id == ^id)
          |> Repo.update_all(set: [sort_order: order, updated_at: DateTime.utc_now()])
        end)

        :reordered
      end)
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
