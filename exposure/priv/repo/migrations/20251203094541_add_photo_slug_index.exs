defmodule Exposure.Repo.Migrations.AddPhotoSlugIndex do
  use Ecto.Migration

  @doc """
  Adds a direct index on photos.slug for efficient slug-based lookups.
  This allows querying photos by slug without loading all photos for a place.
  """
  def change do
    # Direct index on slug for quick lookups in get_photo_with_neighbors
    create(index(:photos, [:slug]))
  end
end
