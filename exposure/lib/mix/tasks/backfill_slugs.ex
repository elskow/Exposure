defmodule Mix.Tasks.BackfillSlugs do
  @moduledoc """
  Backfills country_slug, location_slug, and name_slug for existing places.

  ## Usage

      mix backfill_slugs

  This task will:
  1. Find all places with NULL slugs
  2. Generate slugs from country, location, and name fields
  3. Handle duplicates by appending -2, -3, etc.
  4. Update the database with the new slugs
  """

  use Mix.Task

  require Logger

  @shortdoc "Backfills hierarchical slugs for existing places"

  @impl Mix.Task
  def run(_args) do
    # Start the application so we have access to Repo
    Mix.Task.run("app.start")

    alias Exposure.Repo
    alias Exposure.Gallery.Place
    alias Exposure.Services.SlugGenerator

    import Ecto.Query

    # Find places missing slugs
    places_without_slugs =
      from(p in Place,
        where: is_nil(p.country_slug) or is_nil(p.location_slug) or is_nil(p.name_slug)
      )
      |> Repo.all()

    total = length(places_without_slugs)

    if total == 0 do
      Mix.shell().info("All places already have slugs. Nothing to do.")
    else
      Mix.shell().info("Found #{total} places without slugs. Processing...")

      results =
        places_without_slugs
        |> Enum.with_index(1)
        |> Enum.map(fn {place, index} ->
          Mix.shell().info("[#{index}/#{total}] Processing: #{place.name}")

          country_slug = SlugGenerator.generate(place.country)
          location_slug = SlugGenerator.generate(place.location)

          # For name_slug, check uniqueness within country+location
          name_slug =
            SlugGenerator.generate_unique(place.name, fn slug ->
              from(p in Place,
                where:
                  p.country_slug == ^country_slug and
                    p.location_slug == ^location_slug and
                    p.name_slug == ^slug and
                    p.id != ^place.id
              )
              |> Repo.exists?()
            end)

          attrs = %{
            country_slug: country_slug,
            location_slug: location_slug,
            name_slug: name_slug
          }

          case Repo.update(Place.changeset(place, attrs)) do
            {:ok, _} ->
              Mix.shell().info("  Generated: /#{country_slug}/#{location_slug}/#{name_slug}")
              {:ok, place.id}

            {:error, changeset} ->
              Mix.shell().error("  Failed to update: #{inspect(changeset.errors)}")
              {:error, place.id, "Database update failed"}
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
