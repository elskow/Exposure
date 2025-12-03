defmodule Exposure.Services.FileValidation do
  @moduledoc """
  File validation service for secure file uploads.
  Config is cached using :persistent_term for fast access.
  """

  require Logger

  @default_max_file_size_mb 10
  @default_max_files_per_upload 50
  @default_max_image_width 10_000
  @default_max_image_height 10_000
  @default_max_image_pixels 50_000_000

  @allowed_extensions [".jpg", ".jpeg", ".png", ".webp"]
  @allowed_mime_types ["image/jpeg", "image/png", "image/webp"]

  # Magic numbers for image formats
  @jpeg_magic <<0xFF, 0xD8, 0xFF>>
  @png_magic <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @webp_magic <<0x52, 0x49, 0x46, 0x46>>

  @doc """
  Initializes the config cache using :persistent_term.
  Should be called once at application startup.
  """
  def init_config do
    file_upload_config = Application.get_env(:exposure, :file_upload) || []

    config = %{
      max_file_size_mb: file_upload_config[:max_file_size_mb] || @default_max_file_size_mb,
      max_files_per_upload:
        file_upload_config[:max_files_per_upload] || @default_max_files_per_upload,
      max_image_width: file_upload_config[:max_image_width] || @default_max_image_width,
      max_image_height: file_upload_config[:max_image_height] || @default_max_image_height,
      max_image_pixels: file_upload_config[:max_image_pixels] || @default_max_image_pixels
    }

    :persistent_term.put({__MODULE__, :config}, config)
    Logger.info("FileValidation config initialized: #{inspect(config)}")
    :ok
  end

  @doc """
  Returns the configuration for file uploads.
  Uses :persistent_term for fast access (no Application.get_env calls at runtime).
  """
  def config do
    case :persistent_term.get({__MODULE__, :config}, :not_found) do
      :not_found ->
        # Fallback if not initialized (shouldn't happen in production)
        init_config()
        :persistent_term.get({__MODULE__, :config})

      config ->
        config
    end
  end

  @doc """
  Validates the file count.
  """
  def validate_file_count(0), do: {:error, "No files provided"}

  def validate_file_count(count) do
    max = config().max_files_per_upload

    if count > max do
      {:error, "Too many files (#{count}). Maximum allowed: #{max}"}
    else
      :ok
    end
  end

  @doc """
  Validates a single file upload.
  """
  def validate_file(%Plug.Upload{} = upload) do
    with :ok <- validate_file_name(upload),
         :ok <- validate_file_size(upload),
         :ok <- validate_extension(upload),
         :ok <- validate_mime_type(upload),
         {:ok, format_info} <- validate_magic_number_and_dimensions(upload) do
      {:ok, format_info}
    end
  end

  @doc """
  Validates multiple file uploads.
  """
  def validate_files(files) when is_list(files) do
    case validate_file_count(length(files)) do
      {:error, msg} ->
        {:error, [msg]}

      :ok ->
        errors =
          files
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {file, index} ->
            case validate_file(file) do
              {:ok, _} -> []
              {:error, msg} -> ["File #{index} (#{file.filename}): #{msg}"]
            end
          end)

        if errors == [] do
          :ok
        else
          {:error, errors}
        end
    end
  end

  # Private validation functions

  defp validate_file_name(%Plug.Upload{filename: filename}) do
    cond do
      is_nil(filename) or filename == "" ->
        {:error, "Invalid file name"}

      String.contains?(filename, "..") or String.contains?(filename, "/") or
          String.contains?(filename, "\\") ->
        {:error, "File name contains invalid characters (possible path traversal attempt)"}

      String.length(filename) > 255 ->
        {:error, "File name is too long (max 255 characters)"}

      true ->
        :ok
    end
  end

  defp validate_file_size(%Plug.Upload{path: path}) do
    max_size_bytes = config().max_file_size_mb * 1024 * 1024

    case File.stat(path) do
      {:ok, %{size: 0}} ->
        {:error, "File is empty"}

      {:ok, %{size: size}} when size > max_size_bytes ->
        size_mb = Float.round(size / 1024 / 1024, 2)

        {:error,
         "File size (#{size_mb} MB) exceeds maximum allowed size (#{config().max_file_size_mb} MB)"}

      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, "Unable to read file size"}
    end
  end

  defp validate_extension(%Plug.Upload{filename: filename}) do
    extension = filename |> Path.extname() |> String.downcase()

    cond do
      extension == "" ->
        {:error, "File has no extension"}

      extension not in @allowed_extensions ->
        {:error,
         "File extension '#{extension}' is not allowed. Allowed: #{Enum.join(@allowed_extensions, ", ")}"}

      true ->
        :ok
    end
  end

  defp validate_mime_type(%Plug.Upload{content_type: content_type}) do
    cond do
      is_nil(content_type) or content_type == "" ->
        {:error, "File MIME type is missing"}

      String.downcase(content_type) not in @allowed_mime_types ->
        {:error,
         "MIME type '#{content_type}' is not allowed. Allowed: #{Enum.join(@allowed_mime_types, ", ")}"}

      true ->
        :ok
    end
  end

  defp validate_magic_number_and_dimensions(%Plug.Upload{path: path, filename: filename}) do
    # Only read first 12 bytes to check magic number (most efficient)
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, 12) do
            data when is_binary(data) and byte_size(data) >= 8 ->
              case detect_format_from_magic(data) do
                nil ->
                  {:error,
                   "File content does not match any valid image format (invalid magic number)"}

                format ->
                  Logger.debug("Image #{filename}: detected format #{format}")
                  {:ok, format}
              end

            data when is_binary(data) ->
              {:error, "File is too small to validate (#{byte_size(data)} bytes)"}

            :eof ->
              {:error, "File is empty"}

            {:error, _} ->
              {:error, "Unable to read file content"}
          end
        after
          File.close(file)
        end

      {:error, _} ->
        {:error, "Unable to open file for validation"}
    end
  end

  defp detect_format_from_magic(data) do
    cond do
      binary_part(data, 0, 3) == @jpeg_magic -> "JPEG"
      byte_size(data) >= 8 and binary_part(data, 0, 8) == @png_magic -> "PNG"
      binary_part(data, 0, 4) == @webp_magic -> "WebP"
      true -> nil
    end
  end
end
