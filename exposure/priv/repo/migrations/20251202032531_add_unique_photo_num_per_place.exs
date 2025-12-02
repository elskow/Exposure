defmodule Exposure.Repo.Migrations.AddUniquePhotoNumPerPlace do
  use Ecto.Migration

  def change do
    create(
      unique_index(:photos, [:place_id, :photo_num], name: :photos_place_id_photo_num_unique)
    )
  end
end
