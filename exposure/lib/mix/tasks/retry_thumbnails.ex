defmodule Mix.Tasks.RetryThumbnails do
  @moduledoc """
  Retries thumbnail generation for photos with failed or pending status.

  ## Usage

      # Retry all failed thumbnails
      mix retry_thumbnails

      # Retry all failed thumbnails (dry run - just show what would be retried)
      mix retry_thumbnails --dry-run

      # Also retry pending thumbnails (stuck jobs)
      mix retry_thumbnails --include-pending

      # Retry thumbnails for a specific place
      mix retry_thumbnails --place-id 123

  ## Options

    * `--dry-run` - Show what would be retried without actually queueing jobs
    * `--include-pending` - Also retry photos with "pending" status (may have stuck jobs)
    * `--place-id` - Only retry thumbnails for a specific place
  """

  use Mix.Task

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.Photo
  alias Exposure.Workers.ThumbnailWorker

  @shortdoc "Retry failed thumbnail generation"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          include_pending: :boolean,
          place_id: :integer
        ]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    include_pending = Keyword.get(opts, :include_pending, false)
    place_id = Keyword.get(opts, :place_id)

    # Start the application
    Mix.Task.run("app.start")

    statuses = if include_pending, do: ["failed", "pending"], else: ["failed"]

    query =
      Photo
      |> where([p], p.thumbnail_status in ^statuses)
      |> select([p], %{
        id: p.id,
        place_id: p.place_id,
        file_name: p.file_name,
        status: p.thumbnail_status
      })

    query =
      if place_id do
        where(query, [p], p.place_id == ^place_id)
      else
        query
      end

    photos = Repo.all(query)

    if photos == [] do
      Mix.shell().info("No photos found with status: #{Enum.join(statuses, ", ")}")
    else
      Mix.shell().info("Found #{length(photos)} photos to retry:")

      Enum.each(photos, fn photo ->
        Mix.shell().info(
          "  - Photo #{photo.id} (place #{photo.place_id}): #{photo.file_name} [#{photo.status}]"
        )
      end)

      if dry_run do
        Mix.shell().info("\n[DRY RUN] No jobs were queued.")
      else
        Mix.shell().info("\nQueueing thumbnail jobs...")

        {success, failed} =
          Enum.reduce(photos, {0, 0}, fn photo, {s, f} ->
            # Reset status to pending before queueing
            Photo
            |> where([p], p.id == ^photo.id)
            |> Repo.update_all(set: [thumbnail_status: "pending"])

            case queue_job(photo) do
              {:ok, _} -> {s + 1, f}
              {:error, _} -> {s, f + 1}
            end
          end)

        Mix.shell().info("Queued #{success} jobs successfully, #{failed} failed to queue.")
      end
    end
  end

  defp queue_job(photo) do
    %{photo_id: photo.id, place_id: photo.place_id, file_name: photo.file_name}
    |> ThumbnailWorker.new()
    |> Oban.insert()
  end
end
