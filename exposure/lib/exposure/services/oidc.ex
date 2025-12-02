defmodule Exposure.Services.OIDC do
  @moduledoc """
  OIDC (OpenID Connect) authentication service.

  Supports configurable OIDC providers (Google, GitHub, Keycloak, etc.)
  with optional email/domain restrictions for authorization.
  """

  require Logger

  @doc """
  Returns whether OIDC authentication is enabled.
  """
  def enabled? do
    config()[:enabled] == true
  end

  @doc """
  Returns whether local (username/password) authentication is enabled.
  """
  def local_auth_enabled? do
    Application.get_env(:exposure, :auth)[:local_enabled] != false
  end

  @doc """
  Returns the OIDC provider name for display purposes.
  """
  def provider_name do
    config()[:provider_name] || "SSO"
  end

  @doc """
  Generates the authorization URL for OIDC login.
  Returns {:ok, url, state} or {:error, reason}.
  """
  def authorization_url do
    with {:ok, config} <- get_validated_config() do
      state = generate_state()
      nonce = generate_nonce()

      params = %{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        response_type: "code",
        scope: config.scope,
        state: state,
        nonce: nonce
      }

      query = URI.encode_query(params)
      url = "#{config.authorization_endpoint}?#{query}"

      {:ok, url, state, nonce}
    end
  end

  @doc """
  Exchanges an authorization code for tokens and user info.
  Returns {:ok, user_info} or {:error, reason}.
  """
  def callback(code, state, stored_state, stored_nonce) do
    with :ok <- verify_state(state, stored_state),
         {:ok, config} <- get_validated_config(),
         {:ok, tokens} <- exchange_code(config, code),
         {:ok, user_info} <- get_user_info(config, tokens, stored_nonce),
         :ok <- authorize_user(user_info) do
      {:ok, user_info}
    end
  end

  @doc """
  Returns the OIDC configuration.
  """
  def config do
    Application.get_env(:exposure, :oidc) || %{}
  end

  # Private functions

  defp get_validated_config do
    cfg = config()

    required_fields = [
      :client_id,
      :client_secret,
      :redirect_uri,
      :authorization_endpoint,
      :token_endpoint
    ]

    missing = Enum.filter(required_fields, fn field -> is_nil(cfg[field]) or cfg[field] == "" end)

    if missing == [] do
      {:ok,
       %{
         client_id: cfg[:client_id],
         client_secret: cfg[:client_secret],
         redirect_uri: cfg[:redirect_uri],
         authorization_endpoint: cfg[:authorization_endpoint],
         token_endpoint: cfg[:token_endpoint],
         userinfo_endpoint: cfg[:userinfo_endpoint],
         scope: cfg[:scope] || "openid email profile",
         allowed_emails: cfg[:allowed_emails] || [],
         allowed_domains: cfg[:allowed_domains] || []
       }}
    else
      {:error, "Missing OIDC configuration: #{Enum.join(missing, ", ")}"}
    end
  end

  defp generate_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp verify_state(state, stored_state) do
    if state == stored_state do
      :ok
    else
      {:error, "Invalid state parameter"}
    end
  end

  defp exchange_code(config, code) do
    body = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: config.redirect_uri,
      client_id: config.client_id,
      client_secret: config.client_secret
    }

    case Req.post(config.token_endpoint,
           form: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OIDC token exchange failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Token exchange failed"}

      {:error, reason} ->
        Logger.error("OIDC token exchange error: #{inspect(reason)}")
        {:error, "Token exchange failed"}
    end
  end

  defp get_user_info(config, tokens, stored_nonce) do
    # First, try to extract user info from the ID token
    id_token = Map.get(tokens, "id_token")
    access_token = Map.get(tokens, "access_token")

    cond do
      id_token ->
        case decode_id_token(id_token, stored_nonce) do
          {:ok, claims} -> {:ok, normalize_claims(claims)}
          {:error, _} -> fetch_userinfo(config, access_token)
        end

      access_token && config.userinfo_endpoint ->
        fetch_userinfo(config, access_token)

      true ->
        {:error, "No token available for user info"}
    end
  end

  defp decode_id_token(id_token, stored_nonce) do
    # Simple JWT decoding (without signature verification for now)
    # In production, you should verify the signature using the provider's JWKS
    case String.split(id_token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, claims} ->
                # Verify nonce if present
                token_nonce = Map.get(claims, "nonce")

                if is_nil(token_nonce) or token_nonce == stored_nonce do
                  {:ok, claims}
                else
                  {:error, "Invalid nonce"}
                end

              {:error, _} ->
                {:error, "Invalid token payload"}
            end

          :error ->
            {:error, "Invalid token encoding"}
        end

      _ ->
        {:error, "Invalid token format"}
    end
  end

  defp fetch_userinfo(config, access_token) do
    if config.userinfo_endpoint do
      case Req.get(config.userinfo_endpoint,
             headers: [{"authorization", "Bearer #{access_token}"}]
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, normalize_claims(body)}

        {:ok, %{status: status, body: body}} ->
          Logger.error("OIDC userinfo failed: status=#{status}, body=#{inspect(body)}")
          {:error, "Failed to fetch user info"}

        {:error, reason} ->
          Logger.error("OIDC userinfo error: #{inspect(reason)}")
          {:error, "Failed to fetch user info"}
      end
    else
      {:error, "No userinfo endpoint configured"}
    end
  end

  defp normalize_claims(claims) do
    %{
      sub: Map.get(claims, "sub"),
      email: Map.get(claims, "email"),
      email_verified: Map.get(claims, "email_verified", false),
      name: Map.get(claims, "name") || Map.get(claims, "preferred_username"),
      picture: Map.get(claims, "picture")
    }
  end

  defp authorize_user(user_info) do
    cfg = config()
    allowed_emails = cfg[:allowed_emails] || []
    allowed_domains = cfg[:allowed_domains] || []

    email = user_info[:email]

    cond do
      # No restrictions configured - allow all authenticated users
      allowed_emails == [] and allowed_domains == [] ->
        :ok

      # Check if email is in allowed list
      is_nil(email) ->
        {:error, "Email not provided by identity provider"}

      email in allowed_emails ->
        :ok

      # Check if email domain is allowed
      allowed_domains != [] and email_domain_allowed?(email, allowed_domains) ->
        :ok

      true ->
        {:error, "Your account is not authorized to access this application"}
    end
  end

  defp email_domain_allowed?(email, allowed_domains) do
    case String.split(email, "@") do
      [_, domain] -> domain in allowed_domains
      _ -> false
    end
  end
end
