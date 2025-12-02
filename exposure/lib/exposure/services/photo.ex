defmodule Exposure.Services.Photo do
  @moduledoc """
  Photo service for handling photo uploads, deletions, and reordering.
  """

  require Logger

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.Gallery
  alias Exposure.Gallery.{Place, Photo}
  alias Exposure.Services.{FileValidation, PathValidation, ImageProcessing}

  @doc """
  Uploads photos to a place.
  """
  def upload_photos(place_id, files) when is_list(files) do
    case FileValidation.validate_files(files) do
      {:error, errors} ->
        error_message = Enum.join(errors, "; ")
        Logger.warning("File validation failed for placeId #{place_id}: #{error_message}")
        {:error, error_message}

      :ok ->
        case Repo.get(Place, place_id) do
          nil ->
            Logger.warning("Place not found for upload: #{place_id}")
            {:error, "Place not found"}

          place ->
            do_upload_photos(place, files)
        end
    end
  end

  @doc """
  Deletes a photo by place_id and photo_num.
  """
  def delete_photo(place_id, photo_num) do
    photo =
      Photo
      |> where([p], p.place_id == ^place_id and p.photo_num == ^photo_num)
      |> Repo.one()

    case photo do
      nil ->
        Logger.warning("Photo not found for deletion: placeId #{place_id}, photoNum #{photo_num}")
        false

      photo ->
        # Delete the file and thumbnails
        case PathValidation.get_existing_photo_path(place_id, photo.file_name) do
          {:ok, file_path} ->
            File.rm(file_path)
            directory = Path.dirname(file_path)
            ImageProcessing.delete_thumbnails(photo.file_name, directory)

          {:error, _} ->
            Logger.warning("Path validation error during delete for placeId #{place_id}")
        end

        # Delete from database
        Repo.delete(photo)

        # Renumber remaining photos
        Photo
        |> where([p], p.place_id == ^place_id and p.photo_num > ^photo_num)
        |> Repo.update_all(inc: [photo_num: -1])

        Logger.info("Deleted photo #{photo_num} from placeId #{place_id}")
        true
    end
  end

  @doc """
  Reorders photos for a place.
  Uses raw SQL with CASE for efficient bulk update in 2 queries.
  """
  def reorder_photos(place_id, new_order) when is_list(new_order) do
    photo_count =
      Photo
      |> where([p], p.place_id == ^place_id)
      |> Repo.aggregate(:count)

    if photo_count != length(new_order) do
      Logger.warning(
        "Reorder failed: photo count mismatch for placeId #{place_id}. Expected #{photo_count}, got #{length(new_order)}"
      )

      false
    else
      # Build CASE expression: CASE photo_num WHEN 3 THEN 10001 WHEN 1 THEN 10002 ... END
      case_clauses =
        new_order
        |> Enum.with_index(1)
        |> Enum.map(fn {old_num, new_num} -> "WHEN #{old_num} THEN #{10_000 + new_num}" end)
        |> Enum.join(" ")

      Repo.transaction(fn ->
        # First query: offset using CASE (single query for all updates)
        offset_sql = """
        UPDATE photos 
        SET photo_num = CASE photo_num #{case_clauses} END
        WHERE place_id = $1 AND photo_num IN (#{Enum.join(new_order, ", ")})
        """

        Repo.query!(offset_sql, [place_id])

        # Second query: normalize (already efficient)
        Photo
        |> where([p], p.place_id == ^place_id and p.photo_num >= 10_000)
        |> Repo.update_all(inc: [photo_num: -10_000])
      end)

      Logger.info("Reordered photos for placeId #{place_id}")
      true
    end
  end

  @doc """
  Gets all photos for a place.
  """
  def get_photos_for_place(place_id) do
    Photo
    |> where([p], p.place_id == ^place_id)
    |> order_by([p], asc: p.photo_num)
    |> Repo.all()
  end

  @doc """
  Deletes a place with all its photos.
  """
  def delete_place_with_photos(place_id) do
    case PathValidation.delete_directory_safely(place_id) do
      :ok ->
        Logger.info("Deleted photos directory for placeId #{place_id}")

      {:error, msg} ->
        Logger.warning("Failed to delete photos directory for placeId #{place_id}: #{msg}")
    end

    case Gallery.get_place(place_id) do
      nil ->
        Logger.warning("Failed to delete place #{place_id} from database")
        false

      place ->
        case Gallery.delete_place(place) do
          {:ok, _} ->
            Logger.info("Successfully deleted place #{place_id} with all photos")
            true

          {:error, _} ->
            Logger.warning("Failed to delete place #{place_id} from database")
            false
        end
    end
  end

  @doc """
  Sets or unsets a photo as favorite.
  """
  def set_favorite(place_id, photo_num, is_favorite) do
    Repo.transaction(fn ->
      if is_favorite do
        # Clear existing favorites and set new one in a single transaction
        Photo
        |> where([p], p.place_id == ^place_id and p.is_favorite == true)
        |> Repo.update_all(set: [is_favorite: false])
      end

      # Set or unset the target photo
      updated =
        Photo
        |> where([p], p.place_id == ^place_id and p.photo_num == ^photo_num)
        |> Repo.update_all(set: [is_favorite: is_favorite])

      case updated do
        {count, _} when count > 0 ->
          action = if is_favorite, do: "Set", else: "Removed"
          Logger.info("#{action} favorite for placeId #{place_id}, photoNum #{photo_num}")
          true

        _ ->
          Logger.warning(
            "Photo not found for favorite toggle: placeId #{place_id}, photoNum #{photo_num}"
          )

          Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, true} -> true
      _ -> false
    end
  end

  # Private functions

  defp do_upload_photos(place, files) do
    case PathValidation.create_directory_safely(place.id) do
      {:error, msg} ->
        {:error, msg}

      {:ok, photos_dir} ->
        # Get current max photo number
        current_max =
          Photo
          |> where([p], p.place_id == ^place.id)
          |> select([p], max(p.photo_num))
          |> Repo.one() || 0

        start_num = current_max + 1

        # Process files
        valid_files = Enum.filter(files, fn f -> File.stat!(f.path).size > 0 end)

        {uploaded_count, _errors} =
          valid_files
          |> Enum.with_index(start_num)
          |> Enum.reduce({0, []}, fn {file, photo_num}, {count, errors} ->
            case process_file(file, photos_dir, place.id, photo_num) do
              :ok -> {count + 1, errors}
              {:error, msg} -> {count, [msg | errors]}
            end
          end)

        if uploaded_count > 0 do
          Logger.info("Successfully uploaded #{uploaded_count} photos to placeId #{place.id}")
          {:ok, uploaded_count}
        else
          {:error, "Failed to upload any photos"}
        end
    end
  end

  defp process_file(
         %Plug.Upload{path: path, filename: original_filename},
         photos_dir,
         place_id,
         photo_num
       ) do
    extension =
      original_filename
      |> Path.extname()
      |> String.downcase()
      |> normalize_extension()

    uuid = Ecto.UUID.generate()
    file_name = "#{uuid}#{extension}"
    file_path = Path.join(photos_dir, file_name)

    try do
      # Copy file to destination
      File.cp!(path, file_path)

      # Generate thumbnails - now returns {:ok, %{width: w, height: h}} on success
      case ImageProcessing.generate_thumbnails(file_path, file_name, photos_dir) do
        {:ok, %{width: width, height: height}} ->
          # Save to database with dimensions
          slug =
            Gallery.generate_unique_slug(fn slug ->
              Photo
              |> where([p], p.place_id == ^place_id and p.slug == ^slug)
              |> Repo.exists?()
            end)

          case %Photo{}
               |> Photo.changeset(%{
                 place_id: place_id,
                 photo_num: photo_num,
                 slug: slug,
                 file_name: file_name,
                 is_favorite: false,
                 width: width,
                 height: height
               })
               |> Repo.insert() do
            {:ok, _photo} ->
              Logger.info(
                "Saved photo #{photo_num} for placeId #{place_id}: #{file_name} (#{width}x#{height})"
              )

              :ok

            {:error, changeset} ->
              cleanup_file(file_path, file_name, photos_dir)

              Logger.error(
                "Database save failed for #{original_filename}: #{inspect(changeset.errors)}"
              )

              {:error, "Database error for #{original_filename}"}
          end

        {:error, msg} ->
          cleanup_file(file_path, file_name, photos_dir)
          {:error, "Thumbnails failed: #{msg}"}
      end
    rescue
      e ->
        cleanup_file(file_path, file_name, photos_dir)
        Logger.error("File processing failed for #{original_filename}: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end

  defp normalize_extension(".jpeg"), do: ".jpg"
  defp normalize_extension(ext), do: ext

  defp cleanup_file(file_path, file_name, photos_dir) do
    if File.exists?(file_path), do: File.rm(file_path)
    ImageProcessing.delete_thumbnails(file_name, photos_dir)
  end
end
