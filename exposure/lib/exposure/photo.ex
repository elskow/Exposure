defmodule Exposure.Photo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "photos" do
    field(:slug, :string)
    field(:photo_num, :integer)
    field(:is_favorite, :boolean, default: false)
    field(:file_name, :string)
    field(:width, :integer)
    field(:height, :integer)

    belongs_to(:place, Exposure.Place)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [:slug, :photo_num, :is_favorite, :file_name, :place_id, :width, :height])
    |> validate_required([:slug, :photo_num, :file_name, :place_id])
    |> validate_length(:slug, max: 12)
    |> validate_length(:file_name, max: 255)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> foreign_key_constraint(:place_id)
    |> unique_constraint([:place_id, :slug])
  end
end
