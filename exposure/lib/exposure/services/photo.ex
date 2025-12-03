defmodule Exposure.Services.Photo do
  @moduledoc """
  Photo service for handling photo uploads, deletions, and reordering.
  """

  require Logger

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.{Place, Photo}
  alias Exposure.Services.{FileValidation, PathValidation, ImageProcessing, SlugGenerator}

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
  Uses a two-step UPDATE to avoid unique constraint violations:
  1. Set all photo_nums to negative (temporary)
  2. Set to final positive values
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
      # Ensure all values are integers
      validated_order =
        Enum.map(new_order, fn
          n when is_integer(n) -> n
          n when is_binary(n) -> String.to_integer(n)
        end)

      now = DateTime.utc_now()

      # Use a transaction with two-step update to avoid unique constraint violations
      # Step 1: Set all to negative values (old_num -> -new_num)
      # Step 2: Set all to positive final values (-new_num -> new_num)
      Repo.transaction(fn ->
        # Step 1: Build CASE for old_num -> -new_num
        {case_fragments_1, params_1} =
          validated_order
          |> Enum.with_index(1)
          |> Enum.reduce({[], []}, fn {old_num, new_num}, {fragments, params} ->
            # old_num becomes -new_num (negative to avoid conflicts)
            {["WHEN ? THEN ?" | fragments], [-new_num, old_num | params]}
          end)

        case_sql_1 = "CASE photo_num #{Enum.join(Enum.reverse(case_fragments_1), " ")} END"
        in_placeholders = Enum.map_join(1..length(validated_order), ", ", fn _ -> "?" end)

        sql_1 = """
        UPDATE photos
        SET photo_num = #{case_sql_1},
            updated_at = ?
        WHERE place_id = ? AND photo_num IN (#{in_placeholders})
        """

        all_params_1 = Enum.reverse(params_1) ++ [now, place_id | validated_order]

        case Repo.query(sql_1, all_params_1) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback({:step1_failed, reason})
        end

        # Step 2: Convert negative to positive (-new_num -> new_num)
        # Now update WHERE photo_num < 0
        sql_2 = """
        UPDATE photos
        SET photo_num = -photo_num,
            updated_at = ?
        WHERE place_id = ? AND photo_num < 0
        """

        case Repo.query(sql_2, [now, place_id]) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback({:step2_failed, reason})
        end
      end)
      |> case do
        {:ok, _} ->
          Logger.info("Reordered photos for placeId #{place_id}")
          true

        {:error, reason} ->
          Logger.error("Failed to reorder photos for placeId #{place_id}: #{inspect(reason)}")
          false
      end
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

    case Exposure.get_place(place_id) do
      nil ->
        Logger.warning("Failed to delete place #{place_id} from database")
        false

      place ->
        case Exposure.delete_place(place) do
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

  # ===========================================================================
  # Private functions
  # ===========================================================================

  defp do_upload_photos(place, files) do
    case PathValidation.create_directory_safely(place.id) do
      {:error, msg} ->
        {:error, msg}

      {:ok, photos_dir} ->
        valid_files = Enum.filter(files, fn f -> File.stat!(f.path).size > 0 end)

        {uploaded_count, _errors} =
          valid_files
          |> Enum.reduce({0, []}, fn file, {count, errors} ->
            case process_and_save_photo(file, photos_dir, place.id) do
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

  # Main entry point for processing a single photo upload.
  # Separates file I/O from database operations for proper transaction handling.
  defp process_and_save_photo(
         %Plug.Upload{path: path, filename: original_filename},
         photos_dir,
         place_id
       ) do
    extension =
      original_filename
      |> Path.extname()
      |> String.downcase()
      |> normalize_extension()

    uuid = Ecto.UUID.generate()
    file_name = "#{uuid}#{extension}"
    file_path = Path.join(photos_dir, file_name)

    # Step 1: Process file (copy + thumbnails) OUTSIDE of any transaction
    case process_file_to_disk(path, file_path, file_name, photos_dir) do
      {:ok, dimensions} ->
        # Step 2: Insert to database with retry logic for race conditions
        case insert_photo_with_retry(place_id, file_name, dimensions, photos_dir) do
          {:ok, photo_num} ->
            Logger.info(
              "Saved photo #{photo_num} for placeId #{place_id}: #{file_name} (#{dimensions.width}x#{dimensions.height})"
            )

            :ok

          {:error, reason} ->
            # Clean up files if DB insert failed
            cleanup_file(file_path, file_name, photos_dir)
            Logger.error("Database save failed for #{original_filename}: #{reason}")
            {:error, "Database error for #{original_filename}"}
        end

      {:error, reason} ->
        Logger.error("File processing failed for #{original_filename}: #{reason}")
        {:error, reason}
    end
  end

  # Process file to disk: copy and generate thumbnails.
  # This is done outside of any database transaction.
  # Thumbnails are generated asynchronously for faster response times.
  defp process_file_to_disk(source_path, dest_path, file_name, photos_dir) do
    try do
      # Copy file to destination
      File.cp!(source_path, dest_path)

      # Generate thumbnails asynchronously - returns immediately with dimensions
      case ImageProcessing.generate_thumbnails_async(dest_path, file_name, photos_dir) do
        {:ok, %{width: width, height: height}} ->
          {:ok, %{width: width, height: height}}

        {:error, msg} ->
          cleanup_file(dest_path, file_name, photos_dir)
          {:error, "Thumbnails failed: #{msg}"}
      end
    rescue
      e ->
        cleanup_file(dest_path, file_name, photos_dir)
        {:error, inspect(e)}
    end
  end

  # Insert photo record with retry logic to handle concurrent uploads.
  # Uses optimistic locking: try to insert, retry with new photo_num on conflict.
  @max_insert_retries 5
  defp insert_photo_with_retry(place_id, file_name, dimensions, photos_dir, attempt \\ 1) do
    # Generate a unique slug for this photo
    slug =
      SlugGenerator.generate_random_unique(fn slug ->
        Photo
        |> where([p], p.place_id == ^place_id and p.slug == ^slug)
        |> Repo.exists?()
      end)

    # Use a raw SQL approach with INSERT ... SELECT to atomically get next photo_num
    # This prevents race conditions at the database level
    result = insert_photo_atomic(place_id, file_name, slug, dimensions)

    case result do
      {:ok, photo_num} ->
        {:ok, photo_num}

      {:error, :constraint_violation} when attempt < @max_insert_retries ->
        # Unique constraint violation - another concurrent request got there first
        # Wait a bit with jitter and retry
        jitter = :rand.uniform(50) + attempt * 20
        :timer.sleep(jitter)

        Logger.warning(
          "Retrying photo insert for placeId #{place_id}, attempt #{attempt + 1}/#{@max_insert_retries}"
        )

        insert_photo_with_retry(place_id, file_name, dimensions, photos_dir, attempt + 1)

      {:error, :constraint_violation} ->
        {:error,
         "Failed to insert after #{@max_insert_retries} attempts due to concurrent uploads"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Atomically insert a photo with the next available photo_num.
  # Uses a subquery to get max(photo_num) + 1 in a single statement.
  defp insert_photo_atomic(place_id, file_name, slug, %{width: width, height: height}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Use INSERT with a subquery to atomically determine the next photo_num
    # This is atomic because SQLite executes the entire INSERT as one operation
    sql = """
    INSERT INTO photos (place_id, photo_num, slug, file_name, is_favorite, width, height, inserted_at, updated_at)
    SELECT ?, COALESCE(MAX(photo_num), 0) + 1, ?, ?, 0, ?, ?, ?, ?
    FROM photos
    WHERE place_id = ?
    """

    params = [place_id, slug, file_name, width, height, now, now, place_id]

    case Repo.query(sql, params) do
      {:ok, %{num_rows: 1}} ->
        # Get the photo_num that was just inserted
        case Repo.query("SELECT photo_num FROM photos WHERE place_id = ? AND slug = ?", [
               place_id,
               slug
             ]) do
          {:ok, %{rows: [[photo_num]]}} -> {:ok, photo_num}
          # Fallback, shouldn't happen
          _ -> {:ok, 0}
        end

      {:ok, _} ->
        {:error, :insert_failed}

      {:error, %{sqlite: %{code: :constraint}}} ->
        {:error, :constraint_violation}

      {:error, %Exqlite.Error{message: message}} when is_binary(message) ->
        if String.contains?(message, "UNIQUE constraint") do
          {:error, :constraint_violation}
        else
          {:error, message}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_extension(".jpeg"), do: ".jpg"
  defp normalize_extension(ext), do: ext

  defp cleanup_file(file_path, file_name, photos_dir) do
    if File.exists?(file_path), do: File.rm(file_path)
    ImageProcessing.delete_thumbnails(file_name, photos_dir)
  end
end
