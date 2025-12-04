defmodule Exposure.Services.OrphanCleanup do
  @moduledoc """
  Periodic job to clean up orphaned files and directories.

  This GenServer runs periodically to find and remove:
  1. Photo files on disk without corresponding database records
  2. Place directories that no longer exist in the database
  3. Stale thumbnail generation lock files

  It does NOT delete database records for missing files (that's a more
  invasive operation better done manually with the release task).

  Configuration (in config.exs):
    config :exposure, :orphan_cleanup,
      enabled: true,
      interval_hours: 6,
      file_age_minutes: 30,  # Only delete files older than this
      dry_run: false         # Log what would be deleted without actually deleting
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.{Photo, Place}
  alias Exposure.Services.PathValidation

  @default_interval_hours 6
  @default_file_age_minutes 30
  # Thumbnail suffixes match ImageProcessing.get_suffix/1: -thumb, -small, -medium
  @thumbnail_suffixes ["-thumb", "-small", "-medium"]
  # OG image suffix from OgImageGenerator
  @og_suffix "-og"

  # ===========================================================================
  # Client API
  # ===========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a cleanup run. Returns {:ok, stats} with cleanup statistics.
  """
  def run_now do
    GenServer.call(__MODULE__, :run_now, :infinity)
  end

  @doc """
  Run cleanup directly (useful for release tasks or manual invocation).
  Options:
    - dry_run: true/false (default: false)
    - file_age_minutes: integer (default: 30)
  """
  def cleanup(opts \\ []) do
    do_cleanup(opts)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    config = get_config()

    state = %{
      enabled: config.enabled,
      interval_ms: config.interval_hours * 60 * 60 * 1000,
      file_age_minutes: config.file_age_minutes,
      dry_run: config.dry_run,
      last_run: nil,
      stats: %{}
    }

    if state.enabled do
      # Schedule first run after a delay to let the app fully start
      schedule_cleanup(60_000)
      Logger.info("OrphanCleanup started, will run every #{config.interval_hours} hours")
    else
      Logger.info("OrphanCleanup is disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    stats = do_cleanup(dry_run: state.dry_run, file_age_minutes: state.file_age_minutes)
    new_state = %{state | last_run: DateTime.utc_now(), stats: stats}
    {:reply, {:ok, stats}, new_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Name this background task so it doesn't appear as "Unknown" in New Relic
    NewRelic.set_transaction_name("Background/OrphanCleanup/cleanup")
    stats = do_cleanup(dry_run: state.dry_run, file_age_minutes: state.file_age_minutes)
    new_state = %{state | last_run: DateTime.utc_now(), stats: stats}

    # Schedule next run
    schedule_cleanup(state.interval_ms)

    {:noreply, new_state}
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp schedule_cleanup(delay_ms) do
    Process.send_after(self(), :cleanup, delay_ms)
  end

  defp get_config do
    config = Application.get_env(:exposure, :orphan_cleanup, [])

    %{
      enabled: Keyword.get(config, :enabled, true),
      interval_hours: Keyword.get(config, :interval_hours, @default_interval_hours),
      file_age_minutes: Keyword.get(config, :file_age_minutes, @default_file_age_minutes),
      dry_run: Keyword.get(config, :dry_run, false)
    }
  end

  defp do_cleanup(opts) do
    dry_run = Keyword.get(opts, :dry_run, false)
    file_age_minutes = Keyword.get(opts, :file_age_minutes, @default_file_age_minutes)
    min_age = DateTime.add(DateTime.utc_now(), -file_age_minutes, :minute)

    mode = if dry_run, do: "[DRY RUN] ", else: ""
    Logger.info("#{mode}OrphanCleanup starting...")

    stats = %{
      orphan_files_deleted: 0,
      orphan_directories_deleted: 0,
      lock_files_deleted: 0,
      errors: []
    }

    # Get all valid place IDs from the database
    valid_place_ids = get_valid_place_ids()

    # Get the places directory
    places_dir = get_places_directory()

    stats =
      if File.dir?(places_dir) do
        stats
        |> cleanup_orphan_directories(places_dir, valid_place_ids, dry_run)
        |> cleanup_orphan_files(places_dir, valid_place_ids, min_age, dry_run)
        |> cleanup_lock_files(places_dir, min_age, dry_run)
      else
        Logger.warning("Places directory does not exist: #{places_dir}")
        stats
      end

    Logger.info(
      "#{mode}OrphanCleanup complete: " <>
        "#{stats.orphan_files_deleted} files, " <>
        "#{stats.orphan_directories_deleted} directories, " <>
        "#{stats.lock_files_deleted} lock files deleted"
    )

    if length(stats.errors) > 0 do
      Logger.warning("OrphanCleanup encountered #{length(stats.errors)} errors")
    end

    stats
  end

  defp get_valid_place_ids do
    Place
    |> select([p], p.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp get_places_directory do
    Path.join([PathValidation.wwwroot_path(), "images", "places"])
  end

  # Clean up directories for places that no longer exist
  defp cleanup_orphan_directories(stats, places_dir, valid_place_ids, dry_run) do
    case File.ls(places_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, stats, fn entry, acc ->
          entry_path = Path.join(places_dir, entry)

          if File.dir?(entry_path) do
            case Integer.parse(entry) do
              {place_id, ""} ->
                if not MapSet.member?(valid_place_ids, place_id) do
                  delete_orphan_directory(acc, entry_path, place_id, dry_run)
                else
                  acc
                end

              _ ->
                # Not a numeric directory, skip
                acc
            end
          else
            acc
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to list places directory: #{inspect(reason)}")
        %{stats | errors: [{:list_dir, places_dir, reason} | stats.errors]}
    end
  end

  defp delete_orphan_directory(stats, path, place_id, dry_run) do
    mode = if dry_run, do: "[DRY RUN] ", else: ""
    Logger.info("#{mode}Deleting orphan directory for non-existent place #{place_id}: #{path}")

    if dry_run do
      %{stats | orphan_directories_deleted: stats.orphan_directories_deleted + 1}
    else
      case File.rm_rf(path) do
        {:ok, _} ->
          %{stats | orphan_directories_deleted: stats.orphan_directories_deleted + 1}

        {:error, reason, _} ->
          Logger.error("Failed to delete orphan directory #{path}: #{inspect(reason)}")
          %{stats | errors: [{:delete_dir, path, reason} | stats.errors]}
      end
    end
  end

  # Clean up files that don't have corresponding database records
  defp cleanup_orphan_files(stats, places_dir, valid_place_ids, min_age, dry_run) do
    Enum.reduce(valid_place_ids, stats, fn place_id, acc ->
      place_dir = Path.join(places_dir, Integer.to_string(place_id))

      if File.dir?(place_dir) do
        cleanup_orphan_files_in_place(acc, place_dir, place_id, min_age, dry_run)
      else
        acc
      end
    end)
  end

  defp cleanup_orphan_files_in_place(stats, place_dir, place_id, min_age, dry_run) do
    # Get all file_names for this place from the database
    db_file_names =
      Photo
      |> where([p], p.place_id == ^place_id)
      |> select([p], p.file_name)
      |> Repo.all()
      |> MapSet.new()

    # Also build set of expected thumbnail names and OG images
    expected_files =
      Enum.reduce(db_file_names, db_file_names, fn file_name, acc ->
        name_without_ext = Path.rootname(file_name)

        # Thumbnails: -thumb.webp, -small.webp, -medium.webp
        thumbnails =
          Enum.map(@thumbnail_suffixes, fn suffix ->
            "#{name_without_ext}#{suffix}.webp"
          end)

        # OG image: -og.jpg
        og_image = "#{name_without_ext}#{@og_suffix}.jpg"

        acc
        |> then(fn a -> Enum.reduce(thumbnails, a, &MapSet.put(&2, &1)) end)
        |> MapSet.put(og_image)
      end)

    # List files in the directory
    case File.ls(place_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, stats, fn entry, acc ->
          # Skip lock files (handled separately) and hidden files
          cond do
            String.ends_with?(entry, ".lock") or String.starts_with?(entry, ".") ->
              acc

            # Clean up stale temp files from crashed thumbnail generation
            String.contains?(entry, ".tmp.") and String.ends_with?(entry, ".webp") ->
              file_path = Path.join(place_dir, entry)
              maybe_delete_temp_file(acc, file_path, entry, place_id, min_age, dry_run)

            not MapSet.member?(expected_files, entry) ->
              file_path = Path.join(place_dir, entry)
              maybe_delete_orphan_file(acc, file_path, entry, place_id, min_age, dry_run)

            true ->
              acc
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to list place directory #{place_dir}: #{inspect(reason)}")
        %{stats | errors: [{:list_dir, place_dir, reason} | stats.errors]}
    end
  end

  defp maybe_delete_orphan_file(stats, file_path, file_name, place_id, min_age, dry_run) do
    # Check file age to avoid deleting files that are being uploaded
    case File.stat(file_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        file_time = DateTime.from_unix!(mtime)

        if DateTime.compare(file_time, min_age) == :lt do
          delete_orphan_file(stats, file_path, file_name, place_id, dry_run)
        else
          # File is too new, might be in-progress upload
          stats
        end

      {:error, reason} ->
        Logger.warning("Failed to stat file #{file_path}: #{inspect(reason)}")
        stats
    end
  end

  defp maybe_delete_temp_file(stats, file_path, file_name, place_id, min_age, dry_run) do
    # Check file age - temp files older than min_age are stale and should be cleaned
    case File.stat(file_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        file_time = DateTime.from_unix!(mtime)

        if DateTime.compare(file_time, min_age) == :lt do
          mode = if dry_run, do: "[DRY RUN] ", else: ""
          Logger.info("#{mode}Deleting stale temp file for place #{place_id}: #{file_name}")

          if dry_run do
            %{stats | orphan_files_deleted: stats.orphan_files_deleted + 1}
          else
            case File.rm(file_path) do
              :ok ->
                %{stats | orphan_files_deleted: stats.orphan_files_deleted + 1}

              {:error, reason} ->
                Logger.error("Failed to delete temp file #{file_path}: #{inspect(reason)}")
                %{stats | errors: [{:delete_file, file_path, reason} | stats.errors]}
            end
          end
        else
          # Temp file is recent, might be in-progress
          stats
        end

      {:error, _reason} ->
        stats
    end
  end

  defp delete_orphan_file(stats, file_path, file_name, place_id, dry_run) do
    mode = if dry_run, do: "[DRY RUN] ", else: ""
    Logger.info("#{mode}Deleting orphan file for place #{place_id}: #{file_name}")

    if dry_run do
      %{stats | orphan_files_deleted: stats.orphan_files_deleted + 1}
    else
      case File.rm(file_path) do
        :ok ->
          %{stats | orphan_files_deleted: stats.orphan_files_deleted + 1}

        {:error, reason} ->
          Logger.error("Failed to delete orphan file #{file_path}: #{inspect(reason)}")
          %{stats | errors: [{:delete_file, file_path, reason} | stats.errors]}
      end
    end
  end

  # Clean up stale lock files from thumbnail generation
  defp cleanup_lock_files(stats, places_dir, min_age, dry_run) do
    case File.ls(places_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, stats, fn entry, acc ->
          entry_path = Path.join(places_dir, entry)

          if File.dir?(entry_path) do
            cleanup_lock_files_in_directory(acc, entry_path, min_age, dry_run)
          else
            acc
          end
        end)

      {:error, _} ->
        stats
    end
  end

  defp cleanup_lock_files_in_directory(stats, directory, min_age, dry_run) do
    case File.ls(directory) do
      {:ok, entries} ->
        Enum.reduce(entries, stats, fn entry, acc ->
          if String.ends_with?(entry, ".lock") do
            lock_path = Path.join(directory, entry)

            case File.stat(lock_path, time: :posix) do
              {:ok, %{mtime: mtime}} ->
                file_time = DateTime.from_unix!(mtime)

                if DateTime.compare(file_time, min_age) == :lt do
                  delete_lock_file(acc, lock_path, dry_run)
                else
                  acc
                end

              {:error, _} ->
                acc
            end
          else
            acc
          end
        end)

      {:error, _} ->
        stats
    end
  end

  defp delete_lock_file(stats, lock_path, dry_run) do
    mode = if dry_run, do: "[DRY RUN] ", else: ""
    Logger.debug("#{mode}Deleting stale lock file: #{lock_path}")

    if dry_run do
      %{stats | lock_files_deleted: stats.lock_files_deleted + 1}
    else
      case File.rm(lock_path) do
        :ok ->
          %{stats | lock_files_deleted: stats.lock_files_deleted + 1}

        {:error, reason} ->
          Logger.warning("Failed to delete lock file #{lock_path}: #{inspect(reason)}")
          %{stats | errors: [{:delete_lock, lock_path, reason} | stats.errors]}
      end
    end
  end
end
