defmodule Exposure.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  @doc """
  Adds performance indexes for frequently queried columns.
  """
  def change do
    # Composite index for photo lookups by place_id and photo_num
    # Used in: Services.Photo for ordering, navigation, and reordering
    create(index(:photos, [:place_id, :photo_num]))

    # Partial index for favorite photo lookups
    # Used when clearing/setting favorites within a place
    create(
      index(:photos, [:place_id],
        where: "is_favorite = true",
        name: :photos_favorites_idx
      )
    )

    # Index for places ordering
    # Used in: Gallery.list_places/0 for sorting
    create(index(:places, [:sort_order, :inserted_at]))
  end
end
