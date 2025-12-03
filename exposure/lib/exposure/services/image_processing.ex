defmodule Exposure.Services.ImageProcessing do
  @moduledoc """
  Image processing service for generating thumbnails.
  Supports both synchronous and asynchronous thumbnail generation.
  """

  require Logger

  @thumbnail_sizes %{
    thumb: 200,
    small: 400,
    medium: 800
  }

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
    if not File.exists?(original_path) do
      {:error, "Original file not found"}
    else
      case Image.open(original_path, access: :sequential) do
        {:ok, image} ->
          {width, height, _} = Image.shape(image)

          Logger.debug(
            "Loaded image #{original_path} (#{width}x#{height}) for thumbnail generation"
          )

          # Generate thumbnails in parallel since they're independent operations
          results =
            @thumbnail_sizes
            |> Task.async_stream(
              fn {size, max_dimension} ->
                generate_single_thumbnail(
                  image,
                  base_filename,
                  output_directory,
                  size,
                  max_dimension,
                  {width, height}
                )
              end,
              max_concurrency: 3,
              timeout: 30_000
            )
            |> Enum.map(fn {:ok, result} -> result end)

          errors =
            results
            |> Enum.filter(&match?({:error, _, _}, &1))
            |> Enum.map(fn {:error, size, msg} -> "#{size}: #{msg}" end)

          if errors == [] do
            Logger.info("Generated all thumbnails for #{base_filename}")
            {:ok, %{width: width, height: height}}
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

      {new_width, new_height} = calculate_dimensions(width, height, max_dimension)

      case Image.thumbnail(image, new_width, height: new_height) do
        {:ok, resized} ->
          case Image.write(resized, thumb_path, quality: 80) do
            {:ok, _} ->
              Logger.debug(
                "Generated #{size} thumbnail: #{Path.basename(thumb_path)} (#{new_width}x#{new_height})"
              )

              {:ok, size, thumb_filename}

            {:error, reason} ->
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
