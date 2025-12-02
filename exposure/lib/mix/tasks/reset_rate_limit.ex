defmodule Mix.Tasks.ResetRateLimit do
  @moduledoc """
  Resets the login rate limit for a specific user or all users.

  ## Usage

      # Reset rate limit for a specific user
      mix reset_rate_limit admin

      # Reset rate limits for all users
      mix reset_rate_limit --all

      # Check status for a user
      mix reset_rate_limit --status admin

  ## In Production (with releases)

      # Reset for specific user
      bin/exposure eval "Exposure.Services.RateLimiter.clear(\\"admin\\")"

      # Reset all
      bin/exposure eval "Exposure.Services.RateLimiter.reset_all()"

      # Check status
      bin/exposure eval "Exposure.Services.RateLimiter.get_status(\\"admin\\") |> IO.inspect()"
  """

  use Mix.Task

  @shortdoc "Resets login rate limit for a user"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["--all"] ->
        Exposure.Services.RateLimiter.reset_all()
        Mix.shell().info("Reset rate limits for all users.")

      ["--status", username] when is_binary(username) and username != "" ->
        case Exposure.Services.RateLimiter.get_status(username) do
          nil ->
            Mix.shell().info("No rate limit record for user: #{username}")

          status ->
            Mix.shell().info("""
            Rate limit status for #{username}:
              Attempts: #{status.attempts}
              Window expires in: #{status.window_expires_in_seconds}s
              Locked out: #{status.locked_out}
              Lockout expires in: #{status.lockout_expires_in_seconds}s
            """)
        end

      [username] when is_binary(username) and username != "" ->
        Exposure.Services.RateLimiter.clear(username)
        Mix.shell().info("Reset rate limit for user: #{username}")

      _ ->
        Mix.shell().error("""
        Usage:
          mix reset_rate_limit <username>          # Reset for specific user
          mix reset_rate_limit --all               # Reset for all users
          mix reset_rate_limit --status <username> # Check status for a user
        """)
    end
  end
end
