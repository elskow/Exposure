defmodule Exposure.Services.RateLimiter do
  @moduledoc """
  Simple ETS-based rate limiter for login attempts.
  Limits attempts by username to prevent brute force attacks.
  """

  use GenServer

  @table_name :login_rate_limiter
  @max_attempts 5
  @window_ms 60_000
  @lockout_ms 300_000

  # =============================================================================
  # Client API
  # =============================================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Check if a login attempt is allowed for the given username.
  Returns :ok if allowed, {:error, seconds_remaining} if rate limited.
  """
  def check_rate(username) when is_binary(username) do
    normalized = String.downcase(username)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, normalized) do
      [] ->
        :ok

      [{^normalized, attempts, window_start, lockout_until}] ->
        cond do
          # Check if currently locked out
          lockout_until > now ->
            seconds_remaining = div(lockout_until - now, 1000) + 1
            {:error, seconds_remaining}

          # Check if window has expired, reset
          now - window_start > @window_ms ->
            :ok

          # Check if under limit
          attempts < @max_attempts ->
            :ok

          # Over limit, should be locked out
          true ->
            seconds_remaining = div(@lockout_ms, 1000)
            {:error, seconds_remaining}
        end
    end
  end

  @doc """
  Record a failed login attempt for the given username.
  """
  def record_failure(username) when is_binary(username) do
    normalized = String.downcase(username)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, normalized) do
      [] ->
        # First failure
        :ets.insert(@table_name, {normalized, 1, now, 0})

      [{^normalized, attempts, window_start, _lockout_until}] ->
        cond do
          # Window expired, reset
          now - window_start > @window_ms ->
            :ets.insert(@table_name, {normalized, 1, now, 0})

          # Increment attempts
          attempts + 1 >= @max_attempts ->
            # Lock out the user
            lockout_until = now + @lockout_ms
            :ets.insert(@table_name, {normalized, attempts + 1, window_start, lockout_until})

          true ->
            :ets.insert(@table_name, {normalized, attempts + 1, window_start, 0})
        end
    end

    :ok
  end

  @doc """
  Clear rate limit for a username after successful login.
  """
  def clear(username) when is_binary(username) do
    normalized = String.downcase(username)
    :ets.delete(@table_name, normalized)
    :ok
  end

  @doc """
  Reset all rate limits. Useful for admin operations.
  """
  def reset_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Get current rate limit status for a username.
  Returns nil if no record exists, or a map with attempts and lockout info.
  """
  def get_status(username) when is_binary(username) do
    normalized = String.downcase(username)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, normalized) do
      [] ->
        nil

      [{^normalized, attempts, window_start, lockout_until}] ->
        %{
          username: normalized,
          attempts: attempts,
          window_expires_in_seconds: max(0, div(@window_ms - (now - window_start), 1000)),
          locked_out: lockout_until > now,
          lockout_expires_in_seconds: max(0, div(lockout_until - now, 1000))
        }
    end
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp schedule_cleanup do
    # Clean up expired entries every 5 minutes
    Process.send_after(self(), :cleanup, 300_000)
  end

  defp cleanup_expired_entries do
    now = System.monotonic_time(:millisecond)
    expired_window = now - @window_ms

    # Use select_delete for efficient cleanup without blocking reads
    # Match entries where window has expired AND lockout has expired
    # Pattern: {username, attempts, window_start, lockout_until}
    :ets.select_delete(@table_name, [
      {
        {:"$1", :"$2", :"$3", :"$4"},
        [
          {:andalso, {:<, :"$3", expired_window}, {:<, :"$4", now}}
        ],
        [true]
      }
    ])
  end
end
