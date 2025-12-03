defmodule Exposure.Services.ImageProcessing do
  @moduledoc """
  Image processing service for generating thumbnails.
  Supports both synchronous and asynchronous thumbnail generation.
  Includes retry logic and verification for reliability.

  Thread-safety: This module uses file-based locking to prevent race conditions
  when multiple processes attempt to generate thumbnails for the same image.
  """

  require Logger

  @thumbnail_sizes %{
    thumb: 200,
    small: 400,
    medium: 800
  }

  # Retry configuration
  @max_retries 3
  @retry_delay_ms 500
  @lock_timeout_ms 30_000
  # Timeout for individual thumbnail operations (prevents hang on corrupt images)
  @thumbnail_timeout_ms 60_000

  @doc """
  Gets the thumbnail filename for a given original filename and size.
  """
  def get_thumbnail_filename(original_filename, size) do
    name_without_ext = Path.rootname(original_filename)
    suffix = get_suffix(size)
    "#{name_without_ext}#{suffix}.webp"
  end

  @doc """
  Generates all thumbnail sizes for an image asynchronously.
  Returns {:ok, %{width: w, height: h}} immediately after reading dimensions.
  Thumbnails are generated in the background via Task.Supervisor.
  """
  def generate_thumbnails_async(original_path, base_filename, output_directory) do
    if not File.exists?(original_path) do
      {:error, "Original file not found"}
    else
      case Image.open(original_path, access: :sequential) do
        {:ok, image} ->
          {width, height, _} = Image.shape(image)

          Logger.debug(
            "Loaded image #{original_path} (#{width}x#{height}) - scheduling async thumbnail generation"
          )

          # Schedule thumbnail generation in the background
          Task.Supervisor.start_child(Exposure.TaskSupervisor, fn ->
            generate_thumbnails_sync(original_path, base_filename, output_directory)
          end)

          # Return dimensions immediately
          {:ok, %{width: width, height: height}}

        {:error, reason} ->
          Logger.error("Error loading image #{original_path}: #{inspect(reason)}")
          {:error, "Failed to load image: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Generates all thumbnail sizes for an image synchronously.
  Uses Image library (libvips-based) for processing.
  Returns {:ok, %{width: w, height: h}} on success with original dimensions.
  """
  def generate_thumbnails(original_path, base_filename, output_directory) do
    generate_thumbnails_sync(original_path, base_filename, output_directory)
  end

  defp generate_thumbnails_sync(original_path, base_filename, output_directory) do
    # Use a lock file to prevent concurrent thumbnail generation for the same image
    lock_path = Path.join(output_directory, ".#{base_filename}.lock")

    with_file_lock(lock_path, fn ->
      do_generate_thumbnails(original_path, base_filename, output_directory)
    end)
  end

  defp do_generate_thumbnails(original_path, base_filename, output_directory) do
    # Check file exists right before opening (minimize TOCTOU window)
    case File.stat(original_path) do
      {:error, reason} ->
        {:error, "Original file not found or inaccessible: #{inspect(reason)}"}

      {:ok, %{size: 0}} ->
        {:error, "Original file is empty"}

      {:ok, _stat} ->
        # Use access: :random for better reliability with multiple reads
        case Image.open(original_path, access: :random) do
          {:ok, image} ->
            {width, height, _} = Image.shape(image)

            Logger.debug(
              "Loaded image #{original_path} (#{width}x#{height}) for thumbnail generation"
            )

            # Generate thumbnails sequentially with retry for reliability
            results =
              @thumbnail_sizes
              |> Enum.map(fn {size, max_dimension} ->
                generate_single_thumbnail_with_retry(
                  original_path,
                  base_filename,
                  output_directory,
                  size,
                  max_dimension,
                  {width, height}
                )
              end)

            errors =
              results
              |> Enum.filter(&match?({:error, _, _}, &1))
              |> Enum.map(fn {:error, size, msg} -> "#{size}: #{msg}" end)

            if errors == [] do
              # Verify all thumbnails exist and have valid size
              case verify_thumbnails(base_filename, output_directory) do
                :ok ->
                  Logger.info("Generated and verified all thumbnails for #{base_filename}")
                  {:ok, %{width: width, height: height}}

                {:error, missing} ->
                  Logger.error("Thumbnail verification failed for #{base_filename}: #{missing}")
                  {:error, "Thumbnail verification failed: #{missing}"}
              end
            else
              # Clean up any successfully created thumbnails
              results
              |> Enum.filter(&match?({:ok, _, _}, &1))
              |> Enum.each(fn {:ok, _, filename} ->
                path = Path.join(output_directory, filename)
                File.rm(path)
              end)

              {:error, Enum.join(errors, "; ")}
            end

          {:error, reason} ->
            Logger.error("Error loading image #{original_path}: #{inspect(reason)}")
            {:error, "Failed to load image: #{inspect(reason)}"}
        end
    end
  end

  # Simple file-based locking to prevent concurrent operations on the same image.
  # Uses atomic file creation as a lock mechanism.
  defp with_file_lock(lock_path, fun) do
    case acquire_lock(lock_path, @lock_timeout_ms) do
      :ok ->
        try do
          fun.()
        after
          release_lock(lock_path)
        end

      {:error, :timeout} ->
        {:error, "Timeout waiting for lock on image processing"}
    end
  end

  defp acquire_lock(lock_path, timeout, elapsed \\ 0) do
    if elapsed >= timeout do
      {:error, :timeout}
    else
      # Try to create the lock file exclusively
      case File.open(lock_path, [:write, :exclusive]) do
        {:ok, file} ->
          # Write PID and timestamp to lock file for debugging
          IO.write(file, "#{inspect(self())}:#{System.os_time(:millisecond)}")
          File.close(file)
          :ok

        {:error, :eexist} ->
          # Lock exists, check if it's stale (older than timeout)
          case File.stat(lock_path) do
            {:ok, %{mtime: mtime}} ->
              age_ms = System.os_time(:millisecond) - to_unix_ms(mtime)

              if age_ms > @lock_timeout_ms do
                # Stale lock - try to atomically replace it
                # Use rename from a new temp lock file to avoid race
                temp_lock = "#{lock_path}.#{System.os_time(:nanosecond)}"

                case File.open(temp_lock, [:write, :exclusive]) do
                  {:ok, file} ->
                    IO.write(file, "#{inspect(self())}:#{System.os_time(:millisecond)}")
                    File.close(file)

                    # Atomic rename - if this fails, another process got there first
                    case File.rename(temp_lock, lock_path) do
                      :ok ->
                        :ok

                      {:error, _} ->
                        # Another process got the lock, clean up and retry
                        File.rm(temp_lock)
                        Process.sleep(100)
                        acquire_lock(lock_path, timeout, elapsed + 100)
                    end

                  {:error, _} ->
                    # Couldn't create temp lock, wait and retry
                    Process.sleep(100)
                    acquire_lock(lock_path, timeout, elapsed + 100)
                end
              else
                # Wait and retry
                Process.sleep(100)
                acquire_lock(lock_path, timeout, elapsed + 100)
              end

            {:error, :enoent} ->
              # Lock was released, try again immediately
              acquire_lock(lock_path, timeout, elapsed)

            {:error, _} ->
              # Some other error, wait and retry
              Process.sleep(100)
              acquire_lock(lock_path, timeout, elapsed + 100)
          end

        {:error, _reason} ->
          # Some other error, wait and retry
          Process.sleep(100)
          acquire_lock(lock_path, timeout, elapsed + 100)
      end
    end
  end

  defp release_lock(lock_path) do
    File.rm(lock_path)
  end

  defp to_unix_ms({{year, month, day}, {hour, minute, second}}) do
    NaiveDateTime.new!(year, month, day, hour, minute, second)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  # Retry wrapper for single thumbnail generation with timeout protection
  defp generate_single_thumbnail_with_retry(
         original_path,
         base_filename,
         output_directory,
         size,
         max_dimension,
         dimensions,
         attempt \\ 1
       ) do
    # Wrap in a Task with timeout to prevent hanging on corrupt/malformed images
    task =
      Task.async(fn ->
        do_generate_single_thumbnail_attempt(
          original_path,
          base_filename,
          output_directory,
          size,
          max_dimension,
          dimensions
        )
      end)

    case Task.yield(task, @thumbnail_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _, _} = success} ->
        success

      {:ok, {:error, _, _}} when attempt < @max_retries ->
        Logger.warning(
          "Thumbnail generation failed for #{size} (attempt #{attempt}/#{@max_retries}), retrying..."
        )

        Process.sleep(@retry_delay_ms * attempt)

        generate_single_thumbnail_with_retry(
          original_path,
          base_filename,
          output_directory,
          size,
          max_dimension,
          dimensions,
          attempt + 1
        )

      {:ok, {:error, _, _} = error} ->
        Logger.error("Thumbnail generation failed for #{size} after #{@max_retries} attempts")
        error

      nil ->
        # Task timed out
        Logger.error(
          "Thumbnail generation timed out for #{size} after #{@thumbnail_timeout_ms}ms"
        )

        if attempt < @max_retries do
          Process.sleep(@retry_delay_ms * attempt)

          generate_single_thumbnail_with_retry(
            original_path,
            base_filename,
            output_directory,
            size,
            max_dimension,
            dimensions,
            attempt + 1
          )
        else
          {:error, size, "Thumbnail generation timed out after #{@max_retries} attempts"}
        end

      {:exit, reason} ->
        Logger.error("Thumbnail generation crashed for #{size}: #{inspect(reason)}")

        if attempt < @max_retries do
          Process.sleep(@retry_delay_ms * attempt)

          generate_single_thumbnail_with_retry(
            original_path,
            base_filename,
            output_directory,
            size,
            max_dimension,
            dimensions,
            attempt + 1
          )
        else
          {:error, size, "Thumbnail generation crashed: #{inspect(reason)}"}
        end
    end
  end

  # Actual thumbnail generation attempt (called within Task)
  defp do_generate_single_thumbnail_attempt(
         original_path,
         base_filename,
         output_directory,
         size,
         max_dimension,
         dimensions
       ) do
    # Open a fresh image handle for each thumbnail to avoid stale references
    case Image.open(original_path, access: :random) do
      {:ok, image} ->
        generate_single_thumbnail(
          image,
          base_filename,
          output_directory,
          size,
          max_dimension,
          dimensions
        )

      {:error, reason} ->
        {:error, size, "Failed to open image: #{inspect(reason)}"}
    end
  end

  # Verify all thumbnails exist and have size > 0
  defp verify_thumbnails(base_filename, output_directory) do
    missing =
      @thumbnail_sizes
      |> Map.keys()
      |> Enum.filter(fn size ->
        thumb_filename = get_thumbnail_filename(base_filename, size)
        thumb_path = Path.join(output_directory, thumb_filename)

        case File.stat(thumb_path) do
          {:ok, %{size: file_size}} when file_size > 0 -> false
          _ -> true
        end
      end)

    if missing == [] do
      :ok
    else
      {:error, "Missing or empty: #{Enum.join(missing, ", ")}"}
    end
  end

  @doc """
  Deletes all thumbnails for a given base filename.
  """
  def delete_thumbnails(base_filename, directory) do
    Enum.each(Map.keys(@thumbnail_sizes), fn size ->
      thumb_filename = get_thumbnail_filename(base_filename, size)
      thumb_path = Path.join(directory, thumb_filename)

      if File.exists?(thumb_path) do
        case File.rm(thumb_path) do
          :ok ->
            Logger.debug("Deleted thumbnail: #{thumb_path}")

          {:error, reason} ->
            Logger.warning("Failed to delete thumbnail #{thumb_path}: #{inspect(reason)}")
        end
      end
    end)

    :ok
  end

  # Private functions

  defp get_suffix(:thumb), do: "-thumb"
  defp get_suffix(:small), do: "-small"
  defp get_suffix(:medium), do: "-medium"
  defp get_suffix(_), do: ""

  defp generate_single_thumbnail(
         image,
         base_filename,
         output_directory,
         size,
         max_dimension,
         {width, height}
       ) do
    try do
      thumb_filename = get_thumbnail_filename(base_filename, size)
      thumb_path = Path.join(output_directory, thumb_filename)
      # Temp file must keep .webp extension for libvips to know the output format
      # Format: {name}-thumb.tmp.{timestamp}.{random}.webp
      temp_id = "#{System.os_time(:nanosecond)}.#{:rand.uniform(10000)}"
      temp_filename = "#{Path.rootname(thumb_filename)}.tmp.#{temp_id}.webp"
      temp_path = Path.join(output_directory, temp_filename)

      {new_width, new_height} = calculate_dimensions(width, height, max_dimension)

      case Image.thumbnail(image, new_width, height: new_height) do
        {:ok, resized} ->
          # Write to temp file first
          case Image.write(resized, temp_path, quality: 80) do
            {:ok, _} ->
              # Atomically rename temp to final path
              case File.rename(temp_path, thumb_path) do
                :ok ->
                  Logger.debug(
                    "Generated #{size} thumbnail: #{Path.basename(thumb_path)} (#{new_width}x#{new_height})"
                  )

                  {:ok, size, thumb_filename}

                {:error, reason} ->
                  File.rm(temp_path)
                  {:error, size, "Failed to finalize thumbnail: #{inspect(reason)}"}
              end

            {:error, reason} ->
              File.rm(temp_path)
              {:error, size, "Failed to write thumbnail: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, size, "Failed to resize image: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Error generating #{size} thumbnail: #{inspect(e)}")
        {:error, size, inspect(e)}
    end
  end

  defp calculate_dimensions(width, height, max_dimension) do
    if width > height do
      ratio = max_dimension / width
      {max_dimension, round(height * ratio)}
    else
      ratio = max_dimension / height
      {round(width * ratio), max_dimension}
    end
  end
end
