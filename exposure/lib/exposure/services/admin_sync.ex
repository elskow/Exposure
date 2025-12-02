defmodule Exposure.Services.AdminSync do
  @moduledoc """
  Syncs admin users from configuration to the database on application startup.

  - Creates new admin users that don't exist
  - Updates passwords for existing users if they've changed
  - Does NOT delete users that are removed from config (safety measure)

  Admin users are configured via the :admin_users config key.
  """

  require Logger

  alias Exposure.Repo
  alias Exposure.Gallery.AdminUser
  alias Exposure.Services.Authentication

  import Ecto.Query

  @doc """
  Syncs admin users from config to database.
  Called on application startup.
  """
  def sync do
    admin_users = Application.get_env(:exposure, :admin_users, [])

    if admin_users == [] do
      Logger.warning(
        "No admin users configured. Set :admin_users in config or ADMIN_USERS env var."
      )

      {:ok, 0}
    else
      results =
        Enum.map(admin_users, fn %{username: username, password: password} ->
          sync_user(username, password)
        end)

      created = Enum.count(results, &(&1 == :created))
      updated = Enum.count(results, &(&1 == :updated))
      unchanged = Enum.count(results, &(&1 == :unchanged))

      Logger.info(
        "Admin sync complete: #{created} created, #{updated} updated, #{unchanged} unchanged"
      )

      {:ok, created + updated}
    end
  end

  @doc """
  Syncs a single admin user.
  Returns :created, :updated, or :unchanged.
  """
  def sync_user(username, password) when is_binary(username) and is_binary(password) do
    case get_admin_user(username) do
      nil ->
        create_admin_user(username, password)
        Logger.info("Created admin user: #{username}")
        :created

      user ->
        if password_changed?(user, password) do
          update_password(user, password)
          Logger.info("Updated password for admin user: #{username}")
          :updated
        else
          :unchanged
        end
    end
  end

  defp get_admin_user(username) do
    AdminUser
    |> where([a], a.username == ^username)
    |> Repo.one()
  end

  defp create_admin_user(username, password) do
    %AdminUser{}
    |> AdminUser.changeset(%{
      username: username,
      password_hash: Authentication.hash_password(password),
      totp_enabled: false
    })
    |> Repo.insert!()
  end

  defp password_changed?(user, password) do
    not Authentication.verify_password(password, user.password_hash)
  end

  defp update_password(user, password) do
    user
    |> AdminUser.changeset(%{password_hash: Authentication.hash_password(password)})
    |> Repo.update!()
  end
end
