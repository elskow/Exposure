defmodule Mix.Tasks.GenerateOgImages do
  @moduledoc """
  Generates OG images for existing photos that don't have them yet.

  ## Usage

      # Generate OG images for all photos missing them
      mix generate_og_images

      # Dry run - show what would be generated
      mix generate_og_images --dry-run

      # Force regenerate all OG images (even existing ones)
      mix generate_og_images --force

      # Generate for a specific place only
      mix generate_og_images --place-id 1

  ## Options

    * `--dry-run` - Show what would be generated without actually creating files
    * `--force` - Regenerate all OG images, even if they already exist
    * `--place-id` - Only generate for a specific place
  """

  use Mix.Task

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.{Photo, Place}
  alias Exposure.Services.OgImageGenerator

  @shortdoc "Generate OG images for existing photos"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          force: :boolean,
          place_id: :integer
        ]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)
    place_id = Keyword.get(opts, :place_id)

    # Start the application
    Mix.Task.run("app.start")

    # Query photos with place info
    query =
      from p in Photo,
        join: pl in Place, on: p.place_id == pl.id,
        select: %{
          id: p.id,
          place_id: p.place_id,
          file_name: p.file_name,
          place_name: pl.name,
          location: pl.location,
          country: pl.country
        }

    query =
      if place_id do
        where(query, [p], p.place_id == ^place_id)
      else
        query
      end

    photos = Repo.all(query)

    # Filter to only photos needing OG images (unless --force)
    photos_to_process =
      if force do
        photos
      else
        Enum.filter(photos, fn photo ->
          og_path = get_og_path(photo)
          not File.exists?(og_path)
        end)
      end

    if photos_to_process == [] do
      Mix.shell().info("No photos need OG image generation.")
    else
      Mix.shell().info("Found #{length(photos_to_process)} photos to process:")

      Enum.each(photos_to_process, fn photo ->
        og_path = get_og_path(photo)
        status = if File.exists?(og_path), do: "[exists, will regenerate]", else: "[missing]"
        Mix.shell().info("  - Photo #{photo.id}: #{photo.file_name} #{status}")
      end)

      if dry_run do
        Mix.shell().info("\n[DRY RUN] No files were created.")
      else
        Mix.shell().info("\nGenerating OG images...")

        {success, failed} =
          photos_to_process
          |> Enum.reduce({0, 0}, fn photo, {s, f} ->
            case generate_og_for_photo(photo) do
              :ok ->
                Mix.shell().info("  ✓ #{photo.file_name}")
                {s + 1, f}

              {:error, reason} ->
                Mix.shell().error("  ✗ #{photo.file_name}: #{inspect(reason)}")
                {s, f + 1}
            end
          end)

        Mix.shell().info("\nComplete: #{success} generated, #{failed} failed.")
      end
    end
  end

  defp get_og_path(photo) do
    photos_dir = "priv/static/images/places/#{photo.place_id}"
    og_filename = OgImageGenerator.get_og_filename(photo.file_name)
    Path.join(photos_dir, og_filename)
  end

  defp generate_og_for_photo(photo) do
    photos_dir = "priv/static/images/places/#{photo.place_id}"
    original_path = Path.join(photos_dir, photo.file_name)
    og_path = get_og_path(photo)
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
