defmodule Exposure.Services.PlacesCache do
  @moduledoc """
  ETS-based cache for places data with automatic TTL expiration.
  Reduces database load by caching frequently accessed places list.
  """

  use GenServer

  require Logger

  @table_name :places_cache
  @cache_ttl_ms :timer.minutes(5)
  @cleanup_interval_ms :timer.minutes(1)

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Gets places with stats from cache or fetches from database.
  Returns cached data if available and not expired, otherwise queries database.
  """
  def get_places_with_stats do
    case get_cached(:places_with_stats) do
      {:ok, data} ->
        data

      :miss ->
        # Fetch from database
        data = fetch_places_with_stats()
        put_cached(:places_with_stats, data)
        data
    end
  end

  @doc """
  Invalidates the places cache.
  Should be called when places or photos are modified.
  """
  def invalidate do
    GenServer.cast(__MODULE__, :invalidate)
  end

  @doc """
  Invalidates only the places_with_stats cache.
  """
  def invalidate_places do
    :ets.delete(@table_name, :places_with_stats)
    Logger.debug("Invalidated places_with_stats cache")
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table with public access for fast reads
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("PlacesCache started with #{@cache_ttl_ms}ms TTL")
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:invalidate, state) do
    :ets.delete_all_objects(@table_name)
    Logger.debug("Invalidated all places cache entries")
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp get_cached(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, key) do
      [{^key, data, expires_at}] when expires_at > now ->
        {:ok, data}

      [{^key, _data, _expires_at}] ->
        # Expired, delete and return miss
        :ets.delete(@table_name, key)
        :miss

      [] ->
        :miss
    end
  end

  defp put_cached(key, data) do
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :ets.insert(@table_name, {key, data, expires_at})
    :ok
  end

  defp fetch_places_with_stats do
    # Import the actual database query function
    # We call the raw query version to avoid circular cache calls
    Exposure.list_places_with_stats_uncached()
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    expired_keys =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_key, _data, expires_at} -> expires_at <= now end)
      |> Enum.map(fn {key, _, _} -> key end)

    Enum.each(expired_keys, &:ets.delete(@table_name, &1))

    if length(expired_keys) > 0 do
      Logger.debug("Cleaned up #{length(expired_keys)} expired cache entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
