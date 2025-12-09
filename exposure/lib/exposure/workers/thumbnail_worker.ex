defmodule Exposure.Workers.ThumbnailWorker do
  @moduledoc """
  Oban worker for generating photo thumbnails in the background.

  This worker is responsible for generating all thumbnail sizes (small, thumb, medium)
  for uploaded photos. It includes:
  - Automatic retries with exponential backoff (5 attempts)
  - Unique job constraint to prevent duplicate processing
  - Detailed error logging for debugging
  - Updates photo.thumbnail_status to track progress
  - Trace ID propagation for distributed tracing

  ## Job Arguments
  - `photo_id`: The database ID of the photo
  - `place_id`: The place ID (used for file path)
  - `file_name`: The original file name (UUID-based)
  - `trace_id`: Optional trace ID for request correlation

  ## Thumbnail Status
  - `pending`: Initial state when job is queued
  - `processing`: Set when job starts processing
  - `completed`: Set when all thumbnails generated successfully
  - `failed`: Set when all retries exhausted

  ## Usage
  ```elixir
  %{photo_id: photo.id, place_id: place_id, file_name: file_name, trace_id: trace_id}
  |> Exposure.Workers.ThumbnailWorker.new()
  |> Oban.insert()
  ```
  """

  use Oban.Worker,
    queue: :thumbnails,
    max_attempts: 5,
    # Prevent duplicate jobs for the same photo within 5 minutes
    unique: [period: 300, fields: [:args, :worker]]

  alias Exposure.Observability, as: Log

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.{Photo, Place}
  alias Exposure.Services.{PathValidation, ImageProcessing, OgImageGenerator}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"photo_id" => photo_id, "place_id" => place_id, "file_name" => file_name} = args,
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    # Propagate trace ID from the original request if available
    trace_id = Map.get(args, "trace_id")

    # Use Datadog transaction for background job visibility
    Log.with_transaction("Oban", "ThumbnailWorker", trace_id, fn ->
      Exposure.Tracer.update_span(tags: [photo_id: photo_id, place_id: place_id, attempt: attempt])
      do_perform(photo_id, place_id, file_name, attempt, max_attempts)
    end)
  end

  defp do_perform(photo_id, place_id, file_name, attempt, max_attempts) do
    Log.info("worker.thumbnail.start",
      photo_id: photo_id,
      place_id: place_id,
      attempt: attempt,
      max_attempts: max_attempts
    )

    # First verify the photo still exists in DB
    case get_photo(photo_id) do
      nil ->
        Log.info("worker.thumbnail.cancelled", photo_id: photo_id, reason: "photo_deleted")
        {:cancel, "Photo deleted from database"}

      _photo ->
        # Update status to processing on first attempt
        if attempt == 1, do: update_thumbnail_status(photo_id, "processing")

        result = do_generate_thumbnails(place_id, file_name)

        case result do
          :ok ->
            update_thumbnail_status(photo_id, "completed")
            Log.info("worker.thumbnail.success", photo_id: photo_id, place_id: place_id)
            Log.emit(:thumbnail_generate, %{count: 1}, %{place_id: place_id, status: "success"})
            :ok

          {:cancel, reason} ->
            update_thumbnail_status(photo_id, "failed")
            Log.warning("worker.thumbnail.cancelled", photo_id: photo_id, reason: reason)
            Log.emit(:thumbnail_generate, %{count: 1}, %{place_id: place_id, status: "cancelled"})
            {:cancel, reason}

          {:error, reason} ->
            # Only mark as failed on final attempt
            if attempt >= max_attempts do
              update_thumbnail_status(photo_id, "failed")

              Log.error("worker.thumbnail.failed",
                photo_id: photo_id,
                reason: reason,
                attempts: max_attempts
              )

              Log.emit(:thumbnail_generate_error, %{count: 1}, %{place_id: place_id})
            else
              Log.warning("worker.thumbnail.retry",
                photo_id: photo_id,
                reason: reason,
                attempt: attempt
              )
            end

            {:error, reason}
        end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: 15s, 60s, 135s, 240s, 375s (roughly)
    trunc(:math.pow(attempt, 2) * 15)
  end

  defp do_generate_thumbnails(place_id, file_name) do
    with {:ok, photos_dir} <- PathValidation.get_photo_directory(place_id),
         file_path <- Path.join(photos_dir, file_name),
         :ok <- verify_source_file(file_path),
         {:ok, _dimensions} <-
           ImageProcessing.generate_thumbnails(file_path, file_name, photos_dir),
         :ok <- generate_og_image(place_id, file_path, file_name, photos_dir) do
      :ok
    else
      {:error, :file_not_found} ->
        {:cancel, "Source file not found"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        # Convert any other error types to string
        {:error, inspect(reason)}

      other ->
        # Handle unexpected return values
        {:error, "Unexpected error: #{inspect(other)}"}
    end
  end

  # Generate OG image with place info overlay
  defp generate_og_image(place_id, file_path, file_name, photos_dir) do
    case Repo.get(Place, place_id) do
      nil ->
        Log.warning("worker.og_image.place_not_found", place_id: place_id)
        :ok

      place ->
        og_filename = OgImageGenerator.get_og_filename(file_name)
        og_path = Path.join(photos_dir, og_filename)
        location = "#{place.location}, #{place.country}"

        case OgImageGenerator.generate(file_path, og_path, place.name, location) do
          {:ok, _} ->
            Log.debug("worker.og_image.success", place_id: place_id, file_name: file_name)
            :ok

          {:error, reason} ->
            # OG image generation failure is non-fatal - log and continue
            Log.warning("worker.og_image.failed", place_id: place_id, reason: inspect(reason))
            :ok
        end
    end
  end

  # Get photo from database
  defp get_photo(photo_id) do
    Repo.get(Photo, photo_id)
  end

  # Update the thumbnail_status field
  defp update_thumbnail_status(photo_id, status) do
    Photo
    |> where([p], p.id == ^photo_id)
    |> Repo.update_all(set: [thumbnail_status: status, updated_at: DateTime.utc_now()])
  end

  # Verify the source file exists before attempting thumbnail generation
  defp verify_source_file(file_path) do
    case File.stat(file_path) do
      {:ok, %{size: size}} when size > 0 ->
        :ok

      {:ok, %{size: 0}} ->
        {:error, "Source file is empty"}

      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        {:error, "Cannot access source file: #{inspect(reason)}"}
    end
  end
end
