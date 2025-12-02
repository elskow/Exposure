defmodule Exposure.Repo.Migrations.CreateGalleryTables do
  use Ecto.Migration

  def change do
    create table(:places) do
      add(:slug, :string, null: false, size: 12)
      add(:name, :string, null: false, size: 200)
      add(:location, :string, null: false, size: 100)
      add(:country, :string, null: false, size: 100)
      add(:start_date, :string, null: false, size: 50)
      add(:end_date, :string, size: 50)
      add(:favorites, :integer, default: 0, null: false)
      add(:sort_order, :integer, default: 0, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:places, [:slug]))

    create table(:photos) do
      add(:slug, :string, null: false, size: 12)
      add(:photo_num, :integer, null: false)
      add(:is_favorite, :boolean, default: false, null: false)
      add(:file_name, :string, null: false, size: 255)
      add(:place_id, references(:places, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:photos, [:place_id]))
    create(unique_index(:photos, [:place_id, :slug]))

    create table(:admin_users) do
      add(:username, :string, null: false, size: 100)
      add(:password_hash, :string, null: false, size: 255)
      add(:totp_secret, :string, size: 100)
      add(:totp_enabled, :boolean, default: false, null: false)
      add(:last_login_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:admin_users, [:username]))
  end
end
