defmodule Exposure.Place do
  use Ecto.Schema
  import Ecto.Changeset

  schema "places" do
    field(:country_slug, :string)
    field(:location_slug, :string)
    field(:name_slug, :string)
    field(:name, :string)
    field(:location, :string)
    field(:country, :string)
    field(:start_date, :string)
    field(:end_date, :string)
    field(:favorites, :integer, default: 0)
    field(:sort_order, :integer, default: 0)

    has_many(:photos, Exposure.Photo)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(place, attrs) do
    place
    |> cast(attrs, [
      :country_slug,
      :location_slug,
      :name_slug,
      :name,
      :location,
      :country,
      :start_date,
      :end_date,
      :favorites,
      :sort_order
    ])
    |> validate_required([
      :country_slug,
      :location_slug,
      :name_slug,
      :name,
      :location,
      :country,
      :start_date
    ])
    |> validate_length(:country_slug, max: 50)
    |> validate_length(:location_slug, max: 50)
    |> validate_length(:name_slug, max: 50)
    |> validate_length(:name, max: 200)
    |> validate_length(:location, max: 100)
    |> validate_length(:country, max: 100)
    |> validate_length(:start_date, max: 50)
    |> validate_length(:end_date, max: 50)
    |> unique_constraint([:country_slug, :location_slug, :name_slug])
  end
end
