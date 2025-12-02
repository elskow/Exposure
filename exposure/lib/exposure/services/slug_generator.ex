defmodule Exposure.Services.SlugGenerator do
  @moduledoc """
  Service for generating URL-friendly slugs from text.
  Handles non-ASCII characters, truncation, and duplicate prevention.
  """

  @max_slug_length 30
  @random_slug_chars ~c"abcdefghijklmnopqrstuvwxyz0123456789"
  @random_slug_length 8

  @doc """
  Generates a slug from text.
  - Converts to lowercase
  - Replaces non-alphanumeric chars with hyphens
  - Removes consecutive hyphens
  - Truncates at word boundary to max 30 chars
  - Removes leading/trailing hyphens
  """
  def generate(text) when is_binary(text) do
    text
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> truncate_at_word_boundary(@max_slug_length)
    |> String.trim("-")
  end

  def generate(_), do: ""

  @doc """
  Generates a unique slug by appending -2, -3, etc. if needed.
  Takes an exists_fn that returns true if the slug already exists.
  """
  def generate_unique(text, exists_fn) do
    base_slug = generate(text)
    find_unique_slug(base_slug, exists_fn, 1)
  end

  @doc """
  Generates a random unique slug (8 alphanumeric characters).
  Takes an exists_fn that returns true if the slug already exists.
  """
  def generate_random_unique(exists_fn, attempts \\ 0) do
    if attempts > 100 do
      raise "Failed to generate unique random slug after 100 attempts"
    end

    slug = generate_random_slug()

    if exists_fn.(slug) do
      generate_random_unique(exists_fn, attempts + 1)
    else
      slug
    end
  end

  # Private functions

  defp generate_random_slug do
    for _ <- 1..@random_slug_length, into: "" do
      <<Enum.random(@random_slug_chars)>>
    end
  end

  defp find_unique_slug(base_slug, _exists_fn, attempt) when attempt > 100 do
    raise "Failed to generate unique slug after 100 attempts for: #{base_slug}"
  end

  defp find_unique_slug(base_slug, exists_fn, 1) do
    if exists_fn.(base_slug) do
      find_unique_slug(base_slug, exists_fn, 2)
    else
      base_slug
    end
  end

  defp find_unique_slug(base_slug, exists_fn, attempt) do
    slug = "#{base_slug}-#{attempt}"

    if exists_fn.(slug) do
      find_unique_slug(base_slug, exists_fn, attempt + 1)
    else
      slug
    end
  end

  defp truncate_at_word_boundary(slug, max_length) do
    if String.length(slug) <= max_length do
      slug
    else
      truncated = String.slice(slug, 0, max_length)

      # Find the last hyphen position using :binary.match for efficiency
      case :binary.match(truncated, "-", [{:scope, {byte_size(truncated), -byte_size(truncated)}}]) do
        {pos, _} ->
          # Found a hyphen, truncate there
          :binary.part(truncated, 0, pos)

        :nomatch ->
          # No hyphens, just return truncated
          truncated
      end
    end
  end

  # Basic transliteration for common non-ASCII characters
  defp transliterate(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/u, "")
  end
end
