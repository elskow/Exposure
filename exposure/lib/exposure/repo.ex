defmodule Exposure.Repo do
  use Ecto.Repo,
    otp_app: :exposure,
    adapter: Ecto.Adapters.SQLite3
end
