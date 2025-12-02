defmodule Exposure.Services.Authentication do
  @moduledoc """
  Authentication service for admin users with password hashing and TOTP support.
  """

  alias Exposure.Repo
  alias Exposure.Gallery.AdminUser

  import Ecto.Query

  @generic_auth_error "Invalid credentials"

  @doc """
  Generates a random TOTP secret.
  """
  def generate_totp_secret do
    :crypto.strong_rand_bytes(20)
    |> Base.encode32(padding: false)
  end

  @doc """
  Verifies a TOTP code against a secret.
  """
  def verify_totp_code(secret, code) when is_binary(secret) and is_binary(code) do
    try do
      secret_bytes = Base.decode32!(secret, padding: false)
      # Using NimbleTOTP or manual implementation
      # For now, using a simple time-based verification
      expected = generate_current_totp(secret_bytes)
      # Allow for clock drift (±1 time step)
      codes = [
        generate_totp_at(secret_bytes, -1),
        expected,
        generate_totp_at(secret_bytes, 1)
      ]

      code in codes
    rescue
      _ -> false
    end
  end

  @doc """
  Generates a TOTP QR code as PNG bytes.
  """
  def generate_totp_qr_code(username, secret, issuer) do
    totp_url = "otpauth://totp/#{issuer}:#{username}?secret=#{secret}&issuer=#{issuer}"
    # Using EQRCode library
    totp_url
    |> EQRCode.encode()
    |> EQRCode.png()
  end

  @doc """
  Hashes a password using Argon2 (or PBKDF2 as fallback).
  """
  def hash_password(password) when is_binary(password) do
    # Using PBKDF2 for compatibility
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, 10_000, 32)
    Base.encode64(salt <> hash)
  end

  @doc """
  Verifies a password against a stored hash.
  """
  def verify_password(password, hashed_password)
      when is_binary(password) and is_binary(hashed_password) do
    try do
      <<salt::binary-16, stored_hash::binary-32>> = Base.decode64!(hashed_password)
      computed_hash = :crypto.pbkdf2_hmac(:sha256, password, salt, 10_000, 32)
      secure_compare(stored_hash, computed_hash)
    rescue
      _ -> false
    end
  end

  @doc """
  Gets an admin user by username.
  """
  def get_admin_user(username) when is_binary(username) do
    AdminUser
    |> where([a], a.username == ^username)
    |> Repo.one()
  end

  @doc """
  Creates a new admin user.
  """
  def create_admin_user(username, password) do
    case get_admin_user(username) do
      nil ->
        %AdminUser{}
        |> AdminUser.changeset(%{
          username: username,
          password_hash: hash_password(password),
          totp_enabled: false
        })
        |> Repo.insert()

      _existing ->
        {:error, "User already exists"}
    end
  end

  @doc """
  Enables TOTP for a user.
  """
  def enable_totp(username) do
    case get_admin_user(username) do
      nil ->
        {:error, "User not found"}

      user ->
        if user.totp_enabled and user.totp_secret do
          {:error, "TOTP already enabled"}
        else
          secret = generate_totp_secret()

          user
          |> AdminUser.changeset(%{totp_secret: secret, totp_enabled: true})
          |> Repo.update()
          |> case do
            {:ok, _} -> {:ok, secret}
            {:error, changeset} -> {:error, changeset}
          end
        end
    end
  end

  @doc """
  Disables TOTP for a user.
  """
  def disable_totp(username) do
    case get_admin_user(username) do
      nil ->
        false

      user ->
        case user
             |> AdminUser.changeset(%{totp_secret: nil, totp_enabled: false})
             |> Repo.update() do
          {:ok, _} -> true
          {:error, _} -> false
        end
    end
  end

  @doc """
  Authenticates a user with username, password, and optional TOTP code.
  """
  def authenticate(username, password, totp_code \\ nil) do
    case get_admin_user(username) do
      nil ->
        # Prevent timing attacks
        _ = verify_password(password, hash_password("dummy"))
        {:error, @generic_auth_error}

      user ->
        if not verify_password(password, user.password_hash) do
          {:error, @generic_auth_error}
        else
          if user.totp_enabled do
            case totp_code do
              nil ->
                {:error, @generic_auth_error}

              code ->
                if user.totp_secret && verify_totp_code(user.totp_secret, code) do
                  update_last_login(user)
                  {:ok, user}
                else
                  {:error, @generic_auth_error}
                end
            end
          else
            update_last_login(user)
            {:ok, user}
          end
        end
    end
  end

  # Private functions

  defp update_last_login(user) do
    user
    |> AdminUser.changeset(%{last_login_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  defp generate_current_totp(secret_bytes) do
    generate_totp_at(secret_bytes, 0)
  end

  defp generate_totp_at(secret_bytes, offset) do
    import Bitwise

    time_step = 30
    counter = div(System.os_time(:second), time_step) + offset

    counter_bytes = <<counter::unsigned-big-integer-64>>

    hmac = :crypto.mac(:hmac, :sha, secret_bytes, counter_bytes)
    offset_val = :binary.at(hmac, 19) &&& 0x0F

    <<_::binary-size(offset_val), code::unsigned-big-integer-32, _::binary>> = hmac
    code = (code &&& 0x7FFFFFFF) |> rem(1_000_000)

    code
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
