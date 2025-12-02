defmodule Exposure.Gallery do
  @moduledoc """
  The Gallery context for managing places and photos.
  """

  import Ecto.Query, warn: false
  alias Exposure.Repo
  alias Exposure.Gallery.{Place, Photo, AdminUser}
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
  Increments the favorites count for a place.
  """
  def increment_favorites(%Place{} = place) do
    place
    |> Place.changeset(%{favorites: place.favorites + 1})
    |> Repo.update()
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
  Returns the count of all places.
  """
  def count_places do
    Repo.aggregate(Place, :count)
  end

  @doc """
  Reorders places by the given list of ids.
  All updates happen in a single transaction.
  """
  def reorder_places(ordered_ids) when is_list(ordered_ids) do
    if ordered_ids == [] do
      {:ok, :no_changes}
    else
      Repo.transaction(fn ->
        ordered_ids
        |> Enum.with_index()
        |> Enum.each(fn {id, index} ->
          Place
          |> where([p], p.id == ^id)
          |> Repo.update_all(set: [sort_order: index])
        end)
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
  # Photos
  # =============================================================================

  @doc """
  Gets a single photo by id.
  """
  def get_photo(id), do: Repo.get(Photo, id) |> Repo.preload(:place)

  @doc """
  Gets a photo by place and slug.
  """
  def get_photo_by_slug(place_id, slug) do
    Photo
    |> where([ph], ph.place_id == ^place_id and ph.slug == ^slug)
    |> preload(:place)
    |> Repo.one()
  end

  @doc """
  Creates a photo for a place.
  """
  def create_photo(%Place{} = place, attrs \\ %{}) do
    max_photo_num =
      Photo
      |> where([ph], ph.place_id == ^place.id)
      |> select([ph], max(ph.photo_num))
      |> Repo.one() || 0

    slug_exists_fn = fn slug ->
      Photo
      |> where([ph], ph.place_id == ^place.id and ph.slug == ^slug)
      |> Repo.exists?()
    end

    attrs =
      attrs
      |> Map.put(:place_id, place.id)
      |> Map.put(:photo_num, max_photo_num + 1)
      |> Map.put(:slug, generate_unique_slug(slug_exists_fn))

    %Photo{}
    |> Photo.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a photo.
  """
  def update_photo(%Photo{} = photo, attrs) do
    photo
    |> Photo.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a photo.
  """
  def delete_photo(%Photo{} = photo) do
    Repo.delete(photo)
  end

  @doc """
  Sets a photo as the favorite for its place.
  """
  def set_favorite_photo(%Photo{} = photo) do
    Repo.transaction(fn ->
      # Unset all other favorites for this place
      Photo
      |> where([ph], ph.place_id == ^photo.place_id and ph.id != ^photo.id)
      |> Repo.update_all(set: [is_favorite: false])

      # Set this photo as favorite
      photo
      |> Photo.changeset(%{is_favorite: true})
      |> Repo.update!()
    end)
  end

  # =============================================================================
  # Admin Users
  # =============================================================================

  @doc """
  Gets an admin user by username.
  """
  def get_admin_by_username(username) do
    AdminUser
    |> where([a], a.username == ^username)
    |> Repo.one()
  end

  @doc """
  Creates an admin user.
  """
  def create_admin_user(attrs \\ %{}) do
    %AdminUser{}
    |> AdminUser.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an admin user.
  """
  def update_admin_user(%AdminUser{} = admin_user, attrs) do
    admin_user
    |> AdminUser.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the last login timestamp for an admin user.
  """
  def update_last_login(%AdminUser{} = admin_user) do
    admin_user
    |> AdminUser.changeset(%{last_login_at: DateTime.utc_now()})
    |> Repo.update()
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
