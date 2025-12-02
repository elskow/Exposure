defmodule Exposure.Repo.Migrations.AddDimensionsToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add(:width, :integer)
      add(:height, :integer)
    end
  end
end
