defmodule Exposure.Services.Authentication do
  @moduledoc """
  Authentication service for admin users with password hashing and TOTP support.
  """

  alias Exposure.Repo
  alias Exposure.Gallery.AdminUser

  import Ecto.Query

  @generic_auth_error "Invalid credentials"

  # OWASP recommends 600,000 iterations for PBKDF2-HMAC-SHA256 (as of 2023)
  # https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
  @pbkdf2_iterations 600_000
  @legacy_iterations 10_000

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
  Hashes a password using PBKDF2-HMAC-SHA256.
  Uses 600,000 iterations as per OWASP recommendations.
  """
  def hash_password(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, @pbkdf2_iterations, 32)
    # Prefix with version byte to support future algorithm changes
    Base.encode64(<<1>> <> salt <> hash)
  end

  @doc """
  Verifies a password against a stored hash.
  Supports both new (600K iterations) and legacy (10K iterations) hashes.
  """
  def verify_password(password, hashed_password)
      when is_binary(password) and is_binary(hashed_password) do
    try do
      decoded = Base.decode64!(hashed_password)

      case decoded do
        # New format with version byte
        <<1, salt::binary-16, stored_hash::binary-32>> ->
          computed_hash = :crypto.pbkdf2_hmac(:sha256, password, salt, @pbkdf2_iterations, 32)
          secure_compare(stored_hash, computed_hash)

        # Legacy format without version byte (48 bytes: 16 salt + 32 hash)
        <<salt::binary-16, stored_hash::binary-32>> ->
          computed_hash = :crypto.pbkdf2_hmac(:sha256, password, salt, @legacy_iterations, 32)
          secure_compare(stored_hash, computed_hash)

        _ ->
          false
      end
    rescue
      _ -> false
    end
  end

  @doc """
  Checks if a password hash needs to be upgraded to the new iteration count.
  """
  def needs_rehash?(hashed_password) when is_binary(hashed_password) do
    try do
      decoded = Base.decode64!(hashed_password)
      # If it doesn't start with version byte 1, it needs rehashing
      not match?(<<1, _::binary>>, decoded)
    rescue
      _ -> true
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
    with {:ok, user} <- fetch_user(username),
         :ok <- verify_user_password(user, password),
         :ok <- verify_totp_if_required(user, totp_code) do
      update_last_login(user)
      # Upgrade password hash if using legacy iteration count
      maybe_upgrade_password_hash(user, password)
      {:ok, user}
    else
      :user_not_found ->
        # Prevent timing attacks by doing password hashing anyway
        _ = verify_password(password, hash_password("dummy"))
        {:error, @generic_auth_error}

      :invalid_password ->
        {:error, @generic_auth_error}

      :totp_required ->
        {:error, @generic_auth_error}

      :invalid_totp ->
        {:error, @generic_auth_error}
    end
  end

  defp fetch_user(username) do
    case get_admin_user(username) do
      nil -> :user_not_found
      user -> {:ok, user}
    end
  end

  defp verify_user_password(user, password) do
    if verify_password(password, user.password_hash) do
      :ok
    else
      :invalid_password
    end
  end

  defp verify_totp_if_required(%{totp_enabled: false}, _totp_code), do: :ok

  defp verify_totp_if_required(%{totp_enabled: true}, nil), do: :totp_required

  defp verify_totp_if_required(%{totp_enabled: true, totp_secret: secret}, totp_code) do
    if secret && verify_totp_code(secret, totp_code) do
      :ok
    else
      :invalid_totp
    end
  end

  # Private functions

  defp update_last_login(user) do
    user
    |> AdminUser.changeset(%{last_login_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp maybe_upgrade_password_hash(user, password) do
    if needs_rehash?(user.password_hash) do
      user
      |> AdminUser.changeset(%{password_hash: hash_password(password)})
      |> Repo.update()
    end
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
