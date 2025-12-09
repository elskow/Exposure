defmodule Exposure.Workers.OgImageWorker do
  @moduledoc """
  Oban worker for generating OG images in the background.

  Handles three types of OG images:
  - `home`: Typographic home page OG (regenerated when place count changes)
  - `place`: Magazine cover style place gallery OG
  - `photo`: Individual photo OG (handled by ThumbnailWorker, but can be triggered here too)

  ## Job Arguments
  - `type`: "home" | "place" | "photo"
  - `place_id`: Required for place/photo types
  - `file_name`: Required for photo type
  - `trace_id`: Optional trace ID for request correlation

  ## Usage
  ```elixir
  # Generate home OG
  %{type: "home"}
  |> Exposure.Workers.OgImageWorker.new()
  |> Oban.insert()

  # Generate place gallery OG
  %{type: "place", place_id: place.id}
  |> Exposure.Workers.OgImageWorker.new()
  |> Oban.insert()
  ```
  """

  use Oban.Worker,
    queue: :thumbnails,
    max_attempts: 3,
    unique: [period: 60, fields: [:args, :worker]]

  require Logger

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.{Photo, Place}
  alias Exposure.Services.{OgImageGenerator, PathValidation}
  alias Exposure.Observability, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "home"} = args}) do
    trace_id = Map.get(args, "trace_id")

    Log.with_transaction("Oban", "OgImageWorker/home", trace_id, fn ->
      generate_home_og()
    end)
  end

  def perform(%Oban.Job{args: %{"type" => "place", "place_id" => place_id} = args}) do
    trace_id = Map.get(args, "trace_id")

    Log.with_transaction("Oban", "OgImageWorker/place", trace_id, fn ->
      Exposure.Tracer.update_span(tags: [place_id: place_id])
      generate_place_og(place_id)
    end)
  end

  def perform(%Oban.Job{
        args: %{"type" => "photo", "place_id" => place_id, "file_name" => file_name} = args
      }) do
    trace_id = Map.get(args, "trace_id")

    Log.with_transaction("Oban", "OgImageWorker/photo", trace_id, fn ->
      Exposure.Tracer.update_span(tags: [place_id: place_id])
      generate_photo_og(place_id, file_name)
    end)
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  # =============================================================================
  # Home OG Generation
  # =============================================================================

  defp generate_home_og do
    place_count = Repo.aggregate(Place, :count)

    case OgImageGenerator.generate_home_og(place_count: place_count) do
      {:ok, path} ->
        Log.info("worker.og.home.success", path: path, place_count: place_count)
        :ok

      {:error, reason} ->
        Log.error("worker.og.home.failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  # =============================================================================
  # Place Gallery OG Generation
  # =============================================================================

  defp generate_place_og(place_id) do
    case Repo.get(Place, place_id) do
      nil ->
        Log.info("worker.og.place.cancelled", place_id: place_id, reason: "place_deleted")
        {:cancel, "Place not found"}

      place ->
        do_generate_place_og(place)
    end
  end

  defp do_generate_place_og(place) do
    # Get favorite photo or first photo
    source_file = get_place_source_photo(place.id)

    case source_file do
      nil ->
        Log.info("worker.og.place.skipped", place_id: place.id, reason: "no_photos")
        :ok

      file_name ->
        with {:ok, photos_dir} <- PathValidation.get_photo_directory(place.id),
             original_path <- Path.join(photos_dir, file_name),
             true <- File.exists?(original_path),
             og_path <- Path.join(photos_dir, OgImageGenerator.get_place_og_filename()),
             photo_count <- get_photo_count(place.id),
             trip_dates <- Exposure.trip_dates_display(place.start_date, place.end_date) do
          case OgImageGenerator.generate_place_og(original_path, og_path,
                 place_name: place.name,
                 location: place.location,
                 country: place.country,
                 photo_count: photo_count,
                 trip_dates: trip_dates
               ) do
            {:ok, _} ->
              Log.info("worker.og.place.success", place_id: place.id)
              :ok

            {:error, reason} ->
              Log.error("worker.og.place.failed", place_id: place.id, reason: inspect(reason))
              {:error, reason}
          end
        else
          false ->
            Log.warning("worker.og.place.source_missing",
              place_id: place.id,
              file_name: file_name
            )

            {:error, "Source photo not found"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp get_place_source_photo(place_id) do
    # Try favorite photo first
    favorite =
      Repo.one(
        from(p in Photo,
          where: p.place_id == ^place_id and p.is_favorite == true,
          select: p.file_name,
          limit: 1
        )
      )

    if favorite do
      favorite
    else
      # Fall back to first photo
      Repo.one(
        from(p in Photo,
          where: p.place_id == ^place_id,
          order_by: [asc: p.photo_num],
          select: p.file_name,
          limit: 1
        )
      )
    end
  end

  defp get_photo_count(place_id) do
    Repo.aggregate(from(p in Photo, where: p.place_id == ^place_id), :count)
  end

  # =============================================================================
  # Photo OG Generation (for manual regeneration)
  # =============================================================================

  defp generate_photo_og(place_id, file_name) do
    case Repo.get(Place, place_id) do
      nil ->
        {:cancel, "Place not found"}

      place ->
        with {:ok, photos_dir} <- PathValidation.get_photo_directory(place_id),
             original_path <- Path.join(photos_dir, file_name),
             true <- File.exists?(original_path),
             og_filename <- OgImageGenerator.get_og_filename(file_name),
             og_path <- Path.join(photos_dir, og_filename),
             location <- "#{place.location}, #{place.country}" do
          case OgImageGenerator.generate(original_path, og_path, place.name, location) do
            {:ok, _} ->
              Log.info("worker.og.photo.success", place_id: place_id, file_name: file_name)
              :ok

            {:error, reason} ->
              Log.error("worker.og.photo.failed",
                place_id: place_id,
                file_name: file_name,
                reason: inspect(reason)
              )

              {:error, reason}
          end
        else
          false ->
            {:error, "Source photo not found"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # =============================================================================
  # Public Helpers to Queue Jobs
  # =============================================================================

  @doc """
  Queues a job to regenerate the home page OG image.
  Called when places are added or deleted.
  """
  def queue_home_og(opts \\ []) do
    trace_id = Keyword.get(opts, :trace_id)

    %{type: "home", trace_id: trace_id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Queues a job to generate/regenerate a place gallery OG image.
  Called when a place is created, or when favorite photo changes.
  """
  def queue_place_og(place_id, opts \\ []) do
    trace_id = Keyword.get(opts, :trace_id)

    %{type: "place", place_id: place_id, trace_id: trace_id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Queues a job to regenerate a photo OG image.
  Usually not needed as ThumbnailWorker handles this.
  """
  def queue_photo_og(place_id, file_name, opts \\ []) do
    trace_id = Keyword.get(opts, :trace_id)

    %{type: "photo", place_id: place_id, file_name: file_name, trace_id: trace_id}
    |> new()
    |> Oban.insert()
  end
end
