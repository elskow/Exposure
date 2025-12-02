defmodule Mix.Tasks.BackfillDimensions do
  @moduledoc """
  Backfills width and height for existing photos that are missing dimensions.

  ## Usage

      mix backfill_dimensions

  This task will:
  1. Find all photos with NULL width or height
  2. Read the original image file to get dimensions
  3. Update the database with the dimensions
  """

  use Mix.Task

  require Logger

  @shortdoc "Backfills width and height for existing photos"

  @impl Mix.Task
  def run(_args) do
    # Start the application so we have access to Repo
    Mix.Task.run("app.start")

    alias Exposure.Repo
    alias Exposure.Photo

    import Ecto.Query

    # Find photos missing dimensions
    photos_without_dimensions =
      from(p in Photo,
        where: is_nil(p.width) or is_nil(p.height),
        join: place in assoc(p, :place),
        preload: [place: place]
      )
      |> Repo.all()

    total = length(photos_without_dimensions)

    if total == 0 do
      Mix.shell().info("All photos already have dimensions. Nothing to do.")
    else
      Mix.shell().info("Found #{total} photos without dimensions. Processing...")

      static_path = Application.app_dir(:exposure, "priv/static")

      results =
        photos_without_dimensions
        |> Enum.with_index(1)
        |> Enum.map(fn {photo, index} ->
          image_path =
            Path.join([
              static_path,
              "images",
              "places",
              to_string(photo.place_id),
              photo.file_name
            ])

          Mix.shell().info("[#{index}/#{total}] Processing: #{photo.file_name}")

          if File.exists?(image_path) do
            case Image.open(image_path) do
              {:ok, image} ->
                {width, height, _} = Image.shape(image)

                case Repo.update(Photo.changeset(photo, %{width: width, height: height})) do
                  {:ok, _} ->
                    Mix.shell().info("  Updated: #{width}x#{height}")
                    {:ok, photo.id}

                  {:error, changeset} ->
                    Mix.shell().error("  Failed to update: #{inspect(changeset.errors)}")
                    {:error, photo.id, "Database update failed"}
                end

              {:error, reason} ->
                Mix.shell().error("  Failed to open image: #{inspect(reason)}")
                {:error, photo.id, "Image open failed"}
            end
          else
            Mix.shell().error("  File not found: #{image_path}")
            {:error, photo.id, "File not found"}
          end
        end)

      success_count = Enum.count(results, &match?({:ok, _}, &1))
      error_count = Enum.count(results, &match?({:error, _, _}, &1))

      Mix.shell().info("")
      Mix.shell().info("Backfill complete!")
      Mix.shell().info("  Successful: #{success_count}")
      Mix.shell().info("  Failed: #{error_count}")
    end
  end
end
