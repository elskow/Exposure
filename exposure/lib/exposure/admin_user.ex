defmodule Exposure.AdminUser do
  use Ecto.Schema
  import Ecto.Changeset

  schema "admin_users" do
    field(:username, :string)
    field(:password_hash, :string)
    field(:totp_secret, :string)
    field(:totp_enabled, :boolean, default: false)
    field(:last_login_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(admin_user, attrs) do
    admin_user
    |> cast(attrs, [:username, :password_hash, :totp_secret, :totp_enabled, :last_login_at])
    |> validate_required([:username, :password_hash])
    |> validate_length(:username, min: 3, max: 100)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_-]+$/,
      message: "can only contain letters, numbers, underscores and hyphens"
    )
    |> unique_constraint(:username)
  end
end
