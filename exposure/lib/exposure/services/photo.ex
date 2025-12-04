defmodule Exposure.Services.Photo do
  @moduledoc """
  Photo service for handling photo uploads, deletions, and reordering.
  """

  alias Exposure.Observability, as: Log

  import Ecto.Query

  alias Exposure.Repo
  alias Exposure.{Place, Photo}
  alias Exposure.Services.{FileValidation, PathValidation, ImageProcessing, SlugGenerator}
  alias Exposure.Workers.ThumbnailWorker

  @doc """
  Uploads photos to a place.
  """
  def upload_photos(place_id, files) when is_list(files) do
    case FileValidation.validate_files(files) do
      {:error, errors} ->
        Log.warning("photo.upload.validation_failed", place_id: place_id, errors: length(errors))
        {:error, Enum.join(errors, "; ")}

      :ok ->
        case Repo.get(Place, place_id) do
          nil ->
            Log.warning("photo.upload.place_not_found", place_id: place_id)
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
        Log.warning("photo.delete.not_found", place_id: place_id, photo_num: photo_num)
        false

      photo ->
        # Delete the file and thumbnails
        case PathValidation.get_existing_photo_path(place_id, photo.file_name) do
          {:ok, file_path} ->
            File.rm(file_path)
            directory = Path.dirname(file_path)
            ImageProcessing.delete_thumbnails(photo.file_name, directory)

          {:error, _} ->
            Log.warning("photo.delete.path_error", place_id: place_id, photo_num: photo_num)
        end

        # Delete from database
        Repo.delete(photo)

        # Renumber remaining photos
        Photo
        |> where([p], p.place_id == ^place_id and p.photo_num > ^photo_num)
        |> Repo.update_all(inc: [photo_num: -1])

        Log.info("photo.deleted", place_id: place_id, photo_num: photo_num)
        Log.emit(:photo_delete, %{count: 1}, %{place_id: place_id})
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
      Log.warning("photo.reorder.count_mismatch",
        place_id: place_id,
        expected: photo_count,
        received: length(new_order)
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
          Log.info("photo.reordered", place_id: place_id, count: length(new_order))
          true

        {:error, reason} ->
          Log.error("photo.reorder.failed", place_id: place_id, reason: inspect(reason))
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
        Log.info("place.directory.deleted", place_id: place_id)

      {:error, msg} ->
        Log.warning("place.directory.delete_failed", place_id: place_id, reason: msg)
    end

    case Exposure.get_place(place_id) do
      nil ->
        Log.warning("place.delete.not_found", place_id: place_id)
        false

      place ->
        case Exposure.delete_place(place) do
          {:ok, _} ->
            Log.info("place.deleted", place_id: place_id)
            true

          {:error, _} ->
            Log.error("place.delete.failed", place_id: place_id)
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
          Log.info("photo.favorite.updated",
            place_id: place_id,
            photo_num: photo_num,
            is_favorite: is_favorite
          )

          true

        _ ->
          Log.warning("photo.favorite.not_found", place_id: place_id, photo_num: photo_num)
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
        # Filter valid files, handling potential stat errors gracefully
        # Track why files were filtered out for better error messages
        {valid_files, filtered_count} =
          Enum.reduce(files, {[], 0}, fn f, {valid, filtered} ->
            case File.stat(f.path) do
              {:ok, %{size: size}} when size > 0 -> {[f | valid], filtered}
              _ -> {valid, filtered + 1}
            end
          end)

        valid_files = Enum.reverse(valid_files)

        if valid_files == [] do
          if filtered_count > 0 do
            {:error, "All #{filtered_count} file(s) were unavailable (upload may have timed out)"}
          else
            {:error, "No valid files to upload"}
          end
        else
          {uploaded_count, errors} =
            valid_files
            |> Enum.reduce({0, []}, fn file, {count, errs} ->
              case process_and_save_photo(file, photos_dir, place.id) do
                :ok -> {count + 1, errs}
                {:error, msg} -> {count, [msg | errs]}
              end
            end)

          cond do
            uploaded_count > 0 ->
              Log.info("photo.upload.success", place_id: place.id, count: uploaded_count)
              Log.emit(:photo_upload, %{count: uploaded_count}, %{place_id: place.id})
              {:ok, uploaded_count}

            filtered_count > 0 ->
              {:error,
               "Failed to upload any photos. #{filtered_count} file(s) were unavailable, #{length(errors)} failed processing."}

            true ->
              {:error, "Failed to upload any photos: #{Enum.join(Enum.take(errors, 3), "; ")}"}
          end
        end
    end
  end

  # Main entry point for processing a single photo upload.
  # Copies file to disk, reads dimensions, inserts to DB, then queues thumbnail job.
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

    # Step 1: Copy file to disk and read dimensions (NO thumbnail generation)
    case copy_file_and_read_dimensions(path, file_path) do
      {:ok, dimensions} ->
        # Step 2: Insert to database with retry logic for race conditions
        case insert_photo_with_retry(place_id, file_name, dimensions, photos_dir) do
          {:ok, photo_id, photo_num} ->
            # Step 3: Queue thumbnail generation job
            case queue_thumbnail_job(photo_id, place_id, file_name) do
              {:ok, _job} ->
                Log.info("photo.saved",
                  place_id: place_id,
                  photo_num: photo_num,
                  file_name: file_name,
                  width: dimensions.width,
                  height: dimensions.height
                )

                :ok

              {:error, reason} ->
                # Job queue failed but photo is saved - log warning, don't fail upload
                Log.warning("photo.thumbnail_job.queue_failed",
                  place_id: place_id,
                  photo_num: photo_num,
                  reason: inspect(reason)
                )

                :ok
            end

          {:error, reason} ->
            # Clean up file if DB insert failed
            cleanup_file(file_path, file_name, photos_dir)

            Log.error("photo.save.db_failed",
              place_id: place_id,
              file_name: original_filename,
              reason: reason
            )

            {:error, "Database error for #{original_filename}"}
        end

      {:error, reason} ->
        Log.error("photo.save.file_failed",
          place_id: place_id,
          file_name: original_filename,
          reason: reason
        )

        {:error, reason}
    end
  end

  # Copy file to disk and read dimensions using Image library.
  # Does NOT generate thumbnails - that's handled by the background job.
  # Uses File.read/write instead of File.cp to ensure the entire file is read
  # before the Plug temp file can be cleaned up.
  defp copy_file_and_read_dimensions(source_path, dest_path) do
    try do
      # Read the entire file into memory first - this ensures we have all the data
      # before Plug potentially cleans up the temp file
      case File.read(source_path) do
        {:error, :enoent} ->
          {:error, "Source file no longer exists (upload may have timed out)"}

        {:error, reason} ->
          {:error, "Cannot read source file: #{inspect(reason)}"}

        {:ok, ""} ->
          {:error, "Source file is empty"}

        {:ok, content} ->
          source_size = byte_size(content)

          # Write the content to destination
          case File.write(dest_path, content) do
            :ok ->
              # Verify the write succeeded completely
              case File.stat(dest_path) do
                {:ok, %{size: ^source_size}} ->
                  # Read dimensions from the copied file
                  read_image_dimensions(dest_path)

                {:ok, %{size: actual_size}} ->
                  File.rm(dest_path)

                  {:error,
                   "File write incomplete: expected #{source_size} bytes, got #{actual_size}"}

                {:error, reason} ->
                  File.rm(dest_path)
                  {:error, "Failed to verify written file: #{inspect(reason)}"}
              end

            {:error, :enospc} ->
              {:error, "Disk full - cannot save photo"}

            {:error, reason} ->
              {:error, "Failed to write file: #{inspect(reason)}"}
          end
      end
    rescue
      e ->
        if File.exists?(dest_path), do: File.rm(dest_path)
        {:error, inspect(e)}
    end
  end

  # Read image dimensions using the Image library
  defp read_image_dimensions(file_path) do
    case Image.open(file_path, access: :sequential) do
      {:ok, image} ->
        {width, height, _} = Image.shape(image)
        {:ok, %{width: width, height: height}}

      {:error, reason} ->
        File.rm(file_path)
        {:error, "Failed to read image: #{inspect(reason)}"}
    end
  end

  # Queue thumbnail generation job via Oban with trace ID propagation
  defp queue_thumbnail_job(photo_id, place_id, file_name) do
    trace_id = Log.current_trace_id()

    %{photo_id: photo_id, place_id: place_id, file_name: file_name, trace_id: trace_id}
    |> ThumbnailWorker.new()
    |> Oban.insert()
  end

  # Insert photo record with retry logic to handle concurrent uploads.
  # Uses optimistic locking: try to insert, retry with new photo_num on conflict.
  # Returns {:ok, photo_id, photo_num} on success.
  @max_insert_retries 5
  defp insert_photo_with_retry(place_id, file_name, dimensions, _photos_dir, attempt \\ 1) do
    # Slug generation and insert are both inside the transaction to avoid race conditions
    result = insert_photo_atomic(place_id, file_name, dimensions)

    case result do
      {:ok, photo_id, photo_num} ->
        {:ok, photo_id, photo_num}

      {:error, :constraint_violation} when attempt < @max_insert_retries ->
        # Unique constraint violation - another concurrent request got there first
        # Wait a bit with jitter and retry
        jitter = :rand.uniform(50) + attempt * 20
        :timer.sleep(jitter)

        Log.debug("photo.insert.retry",
          place_id: place_id,
          attempt: attempt + 1,
          max_attempts: @max_insert_retries
        )

        insert_photo_with_retry(place_id, file_name, dimensions, nil, attempt + 1)

      {:error, :constraint_violation} ->
        {:error,
         "Failed to insert after #{@max_insert_retries} attempts due to concurrent uploads"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Atomically insert a photo with the next available photo_num.
  # Uses a transaction with IMMEDIATE mode to ensure atomicity in SQLite.
  # Slug generation is inside the transaction to prevent race conditions.
  # Returns {:ok, photo_id, photo_num} on success.
  defp insert_photo_atomic(place_id, file_name, %{width: width, height: height}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Wrap in a transaction - slug generation AND insert are both inside
    # This prevents race conditions where two requests generate the same slug
    Repo.transaction(fn ->
      # Generate unique slug inside transaction
      slug =
        SlugGenerator.generate_random_unique(fn slug ->
          Photo
          |> where([p], p.place_id == ^place_id and p.slug == ^slug)
          |> Repo.exists?()
        end)

      # Get the next photo_num within the transaction
      case Repo.query("SELECT COALESCE(MAX(photo_num), 0) + 1 FROM photos WHERE place_id = ?", [
             place_id
           ]) do
        {:ok, %{rows: [[next_num]]}} ->
          sql = """
          INSERT INTO photos (place_id, photo_num, slug, file_name, is_favorite, width, height, inserted_at, updated_at)
          VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)
          """

          params = [place_id, next_num, slug, file_name, width, height, now, now]

          case Repo.query(sql, params) do
            {:ok, %{num_rows: 1}} ->
              # SQLite: get the last inserted rowid
              case Repo.query("SELECT last_insert_rowid()") do
                {:ok, %{rows: [[photo_id]]}} ->
                  {photo_id, next_num}

                _ ->
                  Repo.rollback(:insert_failed)
              end

            {:ok, _} ->
              Repo.rollback(:insert_failed)

            {:error, %Exqlite.Error{message: message}} when is_binary(message) ->
              if String.contains?(message, "UNIQUE constraint") do
                Repo.rollback(:constraint_violation)
              else
                Repo.rollback({:db_error, message})
              end

            {:error, reason} ->
              Repo.rollback({:db_error, reason})
          end

        {:error, reason} ->
          Repo.rollback({:db_error, reason})
      end
    end)
    |> case do
      {:ok, {photo_id, photo_num}} -> {:ok, photo_id, photo_num}
      {:error, :constraint_violation} -> {:error, :constraint_violation}
      {:error, :insert_failed} -> {:error, :insert_failed}
      {:error, {:db_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_extension(".jpeg"), do: ".jpg"
  defp normalize_extension(ext), do: ext

  defp cleanup_file(file_path, file_name, photos_dir) do
    if File.exists?(file_path), do: File.rm(file_path)
    ImageProcessing.delete_thumbnails(file_name, photos_dir)
  end
end
