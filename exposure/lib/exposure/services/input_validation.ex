defmodule Exposure.Services.InputValidation do
  @moduledoc """
  Input validation service for sanitizing and validating user input.
  """

  @sql_injection_patterns [
    ~r/(\bOR\b|\bAND\b).*(=|<|>)/i,
    ~r/('|")\s*(OR|AND)\s*('|").*=.*('|").*/i,
    ~r/(UNION|SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|EXEC|EXECUTE)\s+/i,
    ~r/(--|#|\/\*|\*\/)/i,
    ~r/(xp_|sp_|0x[0-9a-fA-F]+)/i
  ]

  @xss_patterns [
    ~r/<script[^>]*>.*?<\/script>/is,
    ~r/javascript:/i,
    ~r/on\w+\s*=/i,
    ~r/<iframe[^>]*>/i,
    ~r/<object[^>]*>/i,
    ~r/<embed[^>]*>/i
  ]

  @path_traversal_patterns [
    ~r/\.\./,
    ~r/(\\|\/)\.\.(\\|\/)/,
    ~r/%2e%2e/i,
    ~r/\.{2,}/
  ]

  @iso_date_regex ~r/^\d{4}-\d{2}-\d{2}$/
  @username_regex ~r/^[a-zA-Z0-9_-]+$/
  @totp_code_regex ~r/^\d{6}$/

  @doc """
  Sanitizes a string by escaping HTML special characters.
  """
  def sanitize_string(nil), do: ""

  def sanitize_string(input) when is_binary(input) do
    input
    |> String.trim()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#x27;")
    |> String.replace("/", "&#x2F;")
  end

  @doc """
  Validates a place name.
  """
  def validate_place_name(name), do: validate_text_field(name, 1, 200, "Place name")

  @doc """
  Validates a location.
  """
  def validate_location(location), do: validate_text_field(location, 1, 100, "Location")

  @doc """
  Validates a country.
  """
  def validate_country(country), do: validate_text_field(country, 1, 100, "Country")

  @doc """
  Validates an ISO date string (YYYY-MM-DD format).
  """
  def validate_iso_date(nil, field_name), do: {:error, "#{field_name} cannot be empty"}
  def validate_iso_date("", field_name), do: {:error, "#{field_name} cannot be empty"}

  def validate_iso_date(date_string, field_name) when is_binary(date_string) do
    if not Regex.match?(@iso_date_regex, date_string) do
      {:error, "#{field_name} must be in YYYY-MM-DD format"}
    else
      case Date.from_iso8601(date_string) do
        {:ok, date} ->
          if date.year >= 1900 and date.year <= 2100 do
            {:ok, date_string}
          else
            {:error, "#{field_name} year must be between 1900 and 2100"}
          end

        {:error, _} ->
          {:error, "#{field_name} is not a valid date"}
      end
    end
  end

  @doc """
  Validates an optional ISO date string.
  """
  def validate_optional_iso_date(nil, _field_name), do: {:ok, nil}
  def validate_optional_iso_date("", _field_name), do: {:ok, nil}

  def validate_optional_iso_date(date_string, field_name) do
    case validate_iso_date(date_string, field_name) do
      {:ok, valid_date} -> {:ok, valid_date}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Validates that end date is not before start date.
  """
  def validate_date_range(_start_date, nil), do: :ok
  def validate_date_range(_start_date, ""), do: :ok

  def validate_date_range(start_date, end_date) do
    with {:ok, start} <- Date.from_iso8601(start_date),
         {:ok, end_d} <- Date.from_iso8601(end_date) do
      if Date.compare(end_d, start) in [:gt, :eq] do
        :ok
      else
        {:error, "End date cannot be before start date"}
      end
    else
      _ -> {:error, "Invalid date format in range validation"}
    end
  end

  @doc """
  Validates a username.
  """
  def validate_username(nil), do: {:error, "Username cannot be empty"}

  def validate_username(username) when is_binary(username) do
    with {:ok, trimmed} <- validate_length(username, 3, 100, "Username"),
         true <- Regex.match?(@username_regex, trimmed),
         false <- contains_sql_injection?(trimmed) do
      {:ok, trimmed}
    else
      false -> {:error, "Username can only contain letters, numbers, underscores and hyphens"}
      true -> {:error, "Username contains invalid characters"}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Validates a password.
  """
  def validate_password(nil), do: {:error, "Password cannot be empty"}
  def validate_password(""), do: {:error, "Password cannot be empty"}

  def validate_password(password) when is_binary(password) do
    cond do
      String.length(password) < 8 -> {:error, "Password must be at least 8 characters"}
      String.length(password) > 100 -> {:error, "Password cannot exceed 100 characters"}
      true -> {:ok, password}
    end
  end

  @doc """
  Validates a TOTP code (6 digits).
  """
  def validate_totp_code(nil), do: {:error, "TOTP code cannot be empty"}
  def validate_totp_code(""), do: {:error, "TOTP code cannot be empty"}

  def validate_totp_code(code) when is_binary(code) do
    if Regex.match?(@totp_code_regex, code) do
      {:ok, code}
    else
      {:error, "TOTP code must be exactly 6 digits"}
    end
  end

  @doc """
  Validates an ID (positive integer).
  """
  def validate_id(id, field_name) when is_integer(id) do
    cond do
      id < 1 -> {:error, "#{field_name} must be greater than 0"}
      id > 999_999 -> {:error, "#{field_name} exceeds maximum value"}
      true -> {:ok, id}
    end
  end

  def validate_id(_, field_name), do: {:error, "#{field_name} must be a valid integer"}

  @doc """
  Validates a complete place form.
  Returns {:ok, {name, location, country, start_date, end_date}} or {:error, errors}
  """
  def validate_place_form(name, location, country, start_date, end_date) do
    results = [
      {:name, validate_place_name(name)},
      {:location, validate_location(location)},
      {:country, validate_country(country)},
      {:start_date, validate_iso_date(start_date, "Start date")},
      {:end_date, validate_optional_iso_date(end_date, "End date")}
    ]

    errors =
      results
      |> Enum.filter(fn {_, result} -> match?({:error, _}, result) end)
      |> Enum.map(fn {_, {:error, msg}} -> msg end)

    if errors == [] do
      results_map = Map.new(results)
      {:ok, name_val} = results_map[:name]
      {:ok, location_val} = results_map[:location]
      {:ok, country_val} = results_map[:country]
      {:ok, start_date_val} = results_map[:start_date]
      {:ok, end_date_val} = results_map[:end_date]

      case validate_date_range(start_date_val, end_date_val) do
        :ok -> {:ok, {name_val, location_val, country_val, start_date_val, end_date_val}}
        {:error, msg} -> {:error, [msg]}
      end
    else
      {:error, errors}
    end
  end

  # Private functions

  defp validate_length(nil, _min, _max, field_name), do: {:error, "#{field_name} cannot be empty"}

  defp validate_length(input, min, max, field_name) when is_binary(input) do
    trimmed = String.trim(input)
    len = String.length(trimmed)

    cond do
      trimmed == "" -> {:error, "#{field_name} cannot be empty"}
      len < min -> {:error, "#{field_name} must be at least #{min} characters"}
      String.length(input) > max -> {:error, "#{field_name} cannot exceed #{max} characters"}
      true -> {:ok, trimmed}
    end
  end

  defp validate_text_field(input, min, max, field_name) do
    with {:ok, trimmed} <- validate_length(input, min, max, field_name),
         false <- contains_sql_injection?(trimmed),
         false <- contains_xss?(trimmed),
         false <- contains_path_traversal?(trimmed) do
      {:ok, trimmed}
    else
      true -> {:error, "#{field_name} contains invalid characters"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp contains_sql_injection?(input) when is_binary(input) do
    Enum.any?(@sql_injection_patterns, &Regex.match?(&1, input))
  end

  defp contains_xss?(input) when is_binary(input) do
    Enum.any?(@xss_patterns, &Regex.match?(&1, input))
  end

  defp contains_path_traversal?(input) when is_binary(input) do
    Enum.any?(@path_traversal_patterns, &Regex.match?(&1, input))
  end
end
