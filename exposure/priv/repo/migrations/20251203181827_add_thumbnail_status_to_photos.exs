defmodule Exposure.Repo.Migrations.AddThumbnailStatusToPhotos do
  use Ecto.Migration

  @doc """
  Adds thumbnail_status column to track thumbnail generation state.

  Status values:
  - "pending": Thumbnail job queued but not yet processed
  - "processing": Currently being generated
  - "completed": All thumbnails generated successfully
  - "failed": Thumbnail generation failed after all retries

  Existing photos are marked as "completed" assuming thumbnails exist.
  """
  def change do
    alter table(:photos) do
      # Default to "pending" for new uploads, existing photos will be set to "completed"
      add(:thumbnail_status, :string, default: "pending", null: false)
    end

    # Create index for querying photos by thumbnail status
    create(index(:photos, [:thumbnail_status]))

    # Set existing photos to "completed" (assuming they have thumbnails)
    execute(
      "UPDATE photos SET thumbnail_status = 'completed' WHERE thumbnail_status = 'pending'",
      "UPDATE photos SET thumbnail_status = 'pending' WHERE thumbnail_status = 'completed'"
    )
  end
end
