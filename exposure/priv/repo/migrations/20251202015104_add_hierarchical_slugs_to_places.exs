defmodule Exposure.Repo.Migrations.AddHierarchicalSlugsToPlaces do
  use Ecto.Migration

  def change do
    # Add new slug columns
    alter table(:places) do
      add(:country_slug, :string, size: 50)
      add(:location_slug, :string, size: 50)
      add(:name_slug, :string, size: 50)
    end

    # Remove old slug column and its index
    drop(unique_index(:places, [:slug]))

    alter table(:places) do
      remove(:slug)
    end

    # Add unique constraint on the combination of all three slugs
    create(unique_index(:places, [:country_slug, :location_slug, :name_slug]))
  end
end
