# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Exposure.Repo.insert!(%Exposure.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Exposure.Services.Authentication

# Create default admin user if it doesn't exist
case Authentication.get_admin_user("admin") do
  nil ->
    case Authentication.create_admin_user("admin", "admin123") do
      {:ok, _user} ->
        IO.puts("Created default admin user: admin / admin123")

      {:error, reason} ->
        IO.puts("Failed to create admin user: #{inspect(reason)}")
    end

  _existing ->
    IO.puts("Admin user already exists")
end
