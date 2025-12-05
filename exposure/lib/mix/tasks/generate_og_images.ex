defmodule Mix.Tasks.GenerateOgImages do
  @moduledoc """
  Generates OG images for the site.

  ## Usage

      # Generate all OG images (home, place galleries, and photo OGs)
      mix generate_og_images

      # Dry run - show what would be generated
      mix generate_og_images --dry-run

      # Force regenerate all OG images (even existing ones)
      mix generate_og_images --force

      # Generate for a specific place only
      mix generate_og_images --place-id 1

      # Generate only the home page OG image
      mix generate_og_images --home-only

      # Generate only place gallery OG images (not individual photos)
      mix generate_og_images --places-only

  ## Options

    * `--dry-run` - Show what would be generated without actually creating files
    * `--force` - Regenerate all OG images, even if they already exist
    * `--place-id` - Only generate for a specific place
    * `--home-only` - Only generate the home page OG image
    * `--places-only` - Only generate place gallery OG images
  """

  use Mix.Task

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.{Photo, Place}
  alias Exposure.Services.OgImageGenerator

  @shortdoc "Generate OG images for home, place galleries, and photos"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          force: :boolean,
          place_id: :integer,
          home_only: :boolean,
          places_only: :boolean
        ]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)
    place_id = Keyword.get(opts, :place_id)
    home_only = Keyword.get(opts, :home_only, false)
    places_only = Keyword.get(opts, :places_only, false)

    # Start the application
    Mix.Task.run("app.start")

    cond do
      home_only ->
        generate_home_og(dry_run, force)

      places_only ->
        generate_place_gallery_ogs(dry_run, force, place_id)

      true ->
        # Generate all OG types
        generate_home_og(dry_run, force)
        generate_place_gallery_ogs(dry_run, force, place_id)
        generate_photo_og_images(dry_run, force, place_id)
    end
  end

  # =============================================================================
  # Home OG
  # =============================================================================

  defp generate_home_og(dry_run, force) do
    Mix.shell().info("=== Home OG Image ===")
    home_og_path = OgImageGenerator.home_og_path()
    place_count = Repo.aggregate(Place, :count)

    if File.exists?(home_og_path) and not force do
      Mix.shell().info("Already exists: #{home_og_path}")
    else
      status = if File.exists?(home_og_path), do: "[regenerate]", else: "[missing]"
      Mix.shell().info("Home OG #{status}")

      if dry_run do
        Mix.shell().info("[DRY RUN] Would generate with #{place_count} destinations")
      else
        case OgImageGenerator.generate_home_og(place_count: place_count) do
          {:ok, path} ->
            Mix.shell().info("  ✓ #{path}")

          {:error, reason} ->
            Mix.shell().error("  ✗ Failed: #{inspect(reason)}")
        end
      end
    end

    Mix.shell().info("")
  end

  # =============================================================================
  # Place Gallery OGs (magazine cover style)
  # =============================================================================

  defp generate_place_gallery_ogs(dry_run, force, place_id_filter) do
    Mix.shell().info("=== Place Gallery OG Images ===")

    # Query all places
    query =
      from(pl in Place,
        select: %{
          id: pl.id,
          name: pl.name,
          location: pl.location,
          country: pl.country,
          start_date: pl.start_date,
          end_date: pl.end_date
        },
        order_by: [asc: pl.id]
      )

    query =
      if place_id_filter do
        where(query, [pl], pl.id == ^place_id_filter)
      else
        query
      end

    places = Repo.all(query)

    # For each place, get favorite photo and photo count
    places =
      Enum.map(places, fn place ->
        # Get favorite photo or first photo
        favorite_photo =
          Repo.one(
            from(p in Photo,
              where: p.place_id == ^place.id and p.is_favorite == true,
              select: p.file_name,
              limit: 1
            )
          )

        first_photo =
          if favorite_photo do
            nil
          else
            Repo.one(
              from(p in Photo,
                where: p.place_id == ^place.id,
                order_by: [asc: p.photo_num],
                select: p.file_name,
                limit: 1
              )
            )
          end

        photo_count = Repo.aggregate(from(p in Photo, where: p.place_id == ^place.id), :count)

        place
        |> Map.put(:favorite_file_name, favorite_photo)
        |> Map.put(:first_file_name, first_photo)
        |> Map.put(:photo_count, photo_count)
      end)

    # Filter places needing OG images
    places_to_process =
      if force do
        places
      else
        Enum.filter(places, fn place ->
          og_path = get_place_og_path(place.id)
          not File.exists?(og_path)
        end)
      end

    if places_to_process == [] do
      Mix.shell().info("All place gallery OGs exist.")
    else
      Mix.shell().info("Found #{length(places_to_process)} places to process:")

      Enum.each(places_to_process, fn place ->
        og_path = get_place_og_path(place.id)
        status = if File.exists?(og_path), do: "[regenerate]", else: "[missing]"
        Mix.shell().info("  - #{place.name} (#{place.photo_count} photos) #{status}")
      end)

      if dry_run do
        Mix.shell().info("\n[DRY RUN] No files created.")
      else
        Mix.shell().info("\nGenerating place gallery OGs...")

        {success, failed} =
          Enum.reduce(places_to_process, {0, 0}, fn place, {s, f} ->
            case generate_place_gallery_og(place) do
              :ok ->
                Mix.shell().info("  ✓ #{place.name}")
                {s + 1, f}

              {:error, reason} ->
                Mix.shell().error("  ✗ #{place.name}: #{inspect(reason)}")
                {s, f + 1}
            end
          end)

        Mix.shell().info("\nPlace galleries: #{success} generated, #{failed} failed.")
      end
    end

    Mix.shell().info("")
  end

  defp get_place_og_path(place_id) do
    Path.join([
      "priv/static/images/places",
      "#{place_id}",
      OgImageGenerator.get_place_og_filename()
    ])
  end

  defp generate_place_gallery_og(place) do
    # Use favorite photo or first photo as background
    source_file = place.favorite_file_name || place.first_file_name

    if source_file do
      photos_dir = "priv/static/images/places/#{place.id}"
      original_path = Path.join(photos_dir, source_file)
      og_path = get_place_og_path(place.id)

      trip_dates = Exposure.trip_dates_display(place.start_date, place.end_date)

      if File.exists?(original_path) do
        case OgImageGenerator.generate_place_og(original_path, og_path,
               place_name: place.name,
               location: place.location,
               country: place.country,
               photo_count: place.photo_count,
               trip_dates: trip_dates
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, "Source photo not found: #{original_path}"}
      end
    else
      {:error, "No photos in place"}
    end
  end

  # =============================================================================
  # Individual Photo OGs
  # =============================================================================

  defp generate_photo_og_images(dry_run, force, place_id) do
    Mix.shell().info("=== Individual Photo OG Images ===")

    query =
      from(p in Photo,
        join: pl in Place,
        on: p.place_id == pl.id,
        select: %{
          id: p.id,
          place_id: p.place_id,
          file_name: p.file_name,
          place_name: pl.name,
          location: pl.location,
          country: pl.country
        }
      )

    query =
      if place_id do
        where(query, [p], p.place_id == ^place_id)
      else
        query
      end

    photos = Repo.all(query)

    photos_to_process =
      if force do
        photos
      else
        Enum.filter(photos, fn photo ->
          og_path = get_photo_og_path(photo)
          not File.exists?(og_path)
        end)
      end

    if photos_to_process == [] do
      Mix.shell().info("All photo OGs exist.")
    else
      Mix.shell().info("Found #{length(photos_to_process)} photos to process:")

      Enum.each(photos_to_process, fn photo ->
        og_path = get_photo_og_path(photo)
        status = if File.exists?(og_path), do: "[regenerate]", else: "[missing]"
        Mix.shell().info("  - Photo #{photo.id}: #{photo.file_name} #{status}")
      end)

      if dry_run do
        Mix.shell().info("\n[DRY RUN] No files created.")
      else
        Mix.shell().info("\nGenerating photo OGs...")

        {success, failed} =
          Enum.reduce(photos_to_process, {0, 0}, fn photo, {s, f} ->
            case generate_og_for_photo(photo) do
              :ok ->
                Mix.shell().info("  ✓ #{photo.file_name}")
                {s + 1, f}

              {:error, reason} ->
                Mix.shell().error("  ✗ #{photo.file_name}: #{inspect(reason)}")
                {s, f + 1}
            end
          end)

        Mix.shell().info("\nPhotos: #{success} generated, #{failed} failed.")
      end
    end

    Mix.shell().info("")
  end

  defp get_photo_og_path(photo) do
    photos_dir = "priv/static/images/places/#{photo.place_id}"
    og_filename = OgImageGenerator.get_og_filename(photo.file_name)
    Path.join(photos_dir, og_filename)
  end

  defp generate_og_for_photo(photo) do
    photos_dir = "priv/static/images/places/#{photo.place_id}"
    original_path = Path.join(photos_dir, photo.file_name)
    og_path = get_photo_og_path(photo)
    location = "#{photo.location}, #{photo.country}"

    if File.exists?(original_path) do
      case OgImageGenerator.generate(original_path, og_path, photo.place_name, location) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Original file not found: #{original_path}"}
    end
  end
end
