defmodule Exposure.Services.PathValidation do
  @moduledoc """
  Path validation service for secure file path handling.
  """

  require Logger
  alias Exposure.Services.InputValidation

  @doc """
  Returns the wwwroot (priv/static) path.

  In production releases with Docker, images are mounted at /app/priv/static
  rather than inside the release structure. Use STATIC_PATH env var to override.
  """
  def wwwroot_path do
    case System.get_env("STATIC_PATH") do
      nil ->
        # Default: use release app_dir (works for dev and standard releases)
        Application.app_dir(:exposure, "priv/static")
        |> Path.expand()

      static_path ->
        # Override: use configured path (for Docker with mounted volumes)
        Path.expand(static_path)
    end
  end

  @doc """
  Validates an ID (positive integer with reasonable bounds).
  Delegates to InputValidation and adds logging for security auditing.
  """
  def validate_id(id, param_name) when is_integer(id) do
    case InputValidation.validate_id(id, param_name) do
      {:ok, valid_id} ->
        {:ok, valid_id}

      {:error, msg} ->
        Logger.warning("Invalid #{param_name}: #{msg}")
        {:error, msg}
    end
  end

  def validate_id(_, param_name), do: {:error, "#{param_name} must be a valid integer"}

  @doc """
  Sanitizes a path component to prevent path traversal.
  """
  def sanitize_path_component(nil), do: {:error, "Invalid path"}
  def sanitize_path_component(""), do: {:error, "Invalid path"}

  def sanitize_path_component(path_component) when is_binary(path_component) do
    cond do
      String.contains?(path_component, "..") ->
        Logger.warning(
          "Path traversal attempt detected: path component contains '..' sequence: #{path_component}"
        )

        {:error, "Invalid path"}

      String.contains?(path_component, "/") or String.contains?(path_component, "\\") ->
        Logger.warning(
          "Path traversal attempt detected: path component contains separator: #{path_component}"
        )

        {:error, "Invalid path"}

      String.contains?(path_component, ":") ->
        Logger.warning("Path validation failed: path component contains colon: #{path_component}")
        {:error, "Invalid path"}

      String.starts_with?(path_component, ".") ->
        Logger.warning(
          "Path validation failed: path component starts with dot: #{path_component}"
        )

        {:error, "Invalid path"}

      true ->
        {:ok, path_component}
    end
  end

  @doc """
  Validates that a path is within the wwwroot directory.
  """
  def validate_path_within_wwwroot(full_path) do
    try do
      normalized_path = Path.expand(full_path)
      root = wwwroot_path()

      if String.starts_with?(normalized_path, root) do
        {:ok, normalized_path}
      else
        Logger.warning(
          "Path traversal attempt blocked: attempted path #{normalized_path} is outside wwwroot #{root}"
        )

        {:error, "Access denied"}
      end
    rescue
      e ->
        Logger.error("Path validation error for path: #{full_path}, error: #{inspect(e)}")
        {:error, "Invalid path"}
    end
  end

  @doc """
  Gets the validated photo directory for a place.
  """
  def get_photo_directory(place_id) do
    with {:ok, valid_id} <- validate_id(place_id, "placeId") do
      relative_path = Path.join(["images", "places", Integer.to_string(valid_id)])
      full_path = Path.join(wwwroot_path(), relative_path)
      validate_path_within_wwwroot(full_path)
    end
  end

  @doc """
  Gets the validated photo path for a place and filename.
  """
  def get_photo_path(place_id, file_name) do
    with {:ok, valid_id} <- validate_id(place_id, "placeId"),
         {:ok, valid_file_name} <- sanitize_path_component(file_name) do
      relative_path =
        Path.join(["images", "places", Integer.to_string(valid_id), valid_file_name])

      full_path = Path.join(wwwroot_path(), relative_path)
      validate_path_within_wwwroot(full_path)
    end
  end

  @doc """
  Gets a validated existing photo path (verifies file exists).
  """
  def get_existing_photo_path(place_id, file_name) do
    with {:ok, valid_path} <- get_photo_path(place_id, file_name) do
      if File.exists?(valid_path) do
        {:ok, valid_path}
      else
        Logger.warning("File not found: #{file_name} for placeId #{place_id}")
        {:error, "File not found"}
      end
    end
  end

  @doc """
  Checks if a path exists and is safe.
  """
  def path_exists_and_safe?(full_path) do
    case validate_path_within_wwwroot(full_path) do
      {:ok, valid_path} -> {:ok, File.exists?(valid_path) or File.dir?(valid_path)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Creates a directory safely within wwwroot.
  """
  def create_directory_safely(place_id) do
    with {:ok, valid_path} <- get_photo_directory(place_id) do
      case File.mkdir_p(valid_path) do
        :ok ->
          Logger.info("Created directory for placeId #{place_id}")
          {:ok, valid_path}

        {:error, reason} ->
          Logger.error("Failed to create directory for placeId #{place_id}: #{inspect(reason)}")
          {:error, "Failed to create directory"}
      end
    end
  end

  @doc """
  Deletes a directory safely within wwwroot.
  """
  def delete_directory_safely(place_id) do
    with {:ok, valid_path} <- get_photo_directory(place_id) do
      if File.dir?(valid_path) do
        case File.rm_rf(valid_path) do
          {:ok, _} ->
            Logger.info("Deleted directory for placeId #{place_id}")
            :ok

          {:error, reason, _} ->
            Logger.error("Failed to delete directory for placeId #{place_id}: #{inspect(reason)}")
            {:error, "Failed to delete directory"}
        end
      else
        :ok
      end
    end
  end
end
