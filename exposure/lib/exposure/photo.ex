defmodule Exposure.Photo do
  use Ecto.Schema
  import Ecto.Changeset

  @thumbnail_statuses ~w(pending processing completed failed)

  schema "photos" do
    field(:slug, :string)
    field(:photo_num, :integer)
    field(:is_favorite, :boolean, default: false)
    field(:file_name, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:thumbnail_status, :string, default: "pending")

    belongs_to(:place, Exposure.Place)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [
      :slug,
      :photo_num,
      :is_favorite,
      :file_name,
      :place_id,
      :width,
      :height,
      :thumbnail_status
    ])
    |> validate_required([:slug, :photo_num, :file_name, :place_id])
    |> validate_length(:slug, max: 12)
    |> validate_length(:file_name, max: 255)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_inclusion(:thumbnail_status, @thumbnail_statuses)
    |> foreign_key_constraint(:place_id)
    |> unique_constraint([:place_id, :slug])
  end

  @doc """
  Returns the list of valid thumbnail statuses.
  """
  def thumbnail_statuses, do: @thumbnail_statuses
end
