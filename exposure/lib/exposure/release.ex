defmodule Exposure.Release do
  @moduledoc """
  Release tasks for running migrations and other setup tasks in production.

  Usage:
    # Run migrations
    ./bin/exposure eval 'Exposure.Release.migrate()'

    # Regenerate missing thumbnails
    ./bin/exposure eval 'Exposure.Release.backfill_thumbnails()'

    # Clean orphan files (dry run)
    ./bin/exposure eval 'Exposure.Release.cleanup_orphans(dry_run: true)'

    # Clean orphan files (for real)
    ./bin/exposure eval 'Exposure.Release.cleanup_orphans()'
  """

  require Logger

  @app :exposure

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Regenerate missing thumbnails for all photos.
  """
  def backfill_thumbnails do
    load_app()

    alias Exposure.Photo
    alias Exposure.Services.{PathValidation, ImageProcessing}

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Exposure.Repo, fn repo ->
        photos = repo.all(Photo)
        total = length(photos)
        IO.puts("Checking #{total} photos for missing thumbnails...")

        {regenerated, errors} =
          photos
          |> Enum.with_index(1)
          |> Enum.reduce({0, 0}, fn {photo, idx}, {regen_count, err_count} ->
            case PathValidation.get_photo_directory(photo.place_id) do
              {:ok, photos_dir} ->
                file_path = Path.join(photos_dir, photo.file_name)

                if File.exists?(file_path) do
                  thumb_path = Path.join(photos_dir, "thumb_#{photo.file_name}")
                  medium_path = Path.join(photos_dir, "medium_#{photo.file_name}")
                  large_path = Path.join(photos_dir, "large_#{photo.file_name}")

                  missing_thumbnails =
                    [thumb_path, medium_path, large_path]
                    |> Enum.reject(&File.exists?/1)

                  if length(missing_thumbnails) > 0 do
                    IO.puts("[#{idx}/#{total}] Regenerating thumbnails for #{photo.file_name}...")

                    case ImageProcessing.generate_thumbnails(
                           file_path,
                           photo.file_name,
                           photos_dir
                         ) do
                      {:ok, _} ->
                        {regen_count + 1, err_count}

                      {:error, reason} ->
                        IO.puts("  ERROR: #{reason}")
                        {regen_count, err_count + 1}
                    end
                  else
                    {regen_count, err_count}
                  end
                else
                  IO.puts("[#{idx}/#{total}] Source file missing: #{photo.file_name}")
                  {regen_count, err_count + 1}
                end

              {:error, _} ->
                {regen_count, err_count + 1}
            end
          end)

        IO.puts("\nComplete! Regenerated: #{regenerated}, Errors: #{errors}")
      end)
  end

  @doc """
  Clean up orphaned files on disk that have no corresponding database records.

  Options:
    - dry_run: true/false (default: false) - preview without deleting
    - file_age_minutes: integer (default: 30) - only delete files older than this

  Examples:
    # Preview what would be deleted
    Exposure.Release.cleanup_orphans(dry_run: true)

    # Actually delete orphans
    Exposure.Release.cleanup_orphans()

    # Delete orphans older than 5 minutes
    Exposure.Release.cleanup_orphans(file_age_minutes: 5)
  """
  def cleanup_orphans(opts \\ []) do
    load_app()

    dry_run = Keyword.get(opts, :dry_run, false)
    file_age_minutes = Keyword.get(opts, :file_age_minutes, 30)

    mode = if dry_run, do: "[DRY RUN] ", else: ""
    IO.puts("#{mode}Running orphan cleanup...")
    IO.puts("Files must be older than #{file_age_minutes} minutes to be deleted.\n")

    {:ok, stats, _} =
      Ecto.Migrator.with_repo(Exposure.Repo, fn _repo ->
        Exposure.Services.OrphanCleanup.cleanup(opts)
      end)

    IO.puts("\n#{mode}Results:")
    IO.puts("  Orphan files deleted: #{stats.orphan_files_deleted}")
    IO.puts("  Orphan directories deleted: #{stats.orphan_directories_deleted}")
    IO.puts("  Lock files deleted: #{stats.lock_files_deleted}")

    if length(stats.errors) > 0 do
      IO.puts("\n  Errors encountered: #{length(stats.errors)}")

      Enum.each(stats.errors, fn {type, path, reason} ->
        IO.puts("    - #{type}: #{path} (#{inspect(reason)})")
      end)
    end

    stats
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
