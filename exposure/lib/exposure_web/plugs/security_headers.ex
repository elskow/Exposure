defmodule ExposureWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Plug that adds comprehensive security headers to all responses.

  This includes protection against:
  - Clickjacking (X-Frame-Options)
  - MIME type sniffing (X-Content-Type-Options)
  - XSS attacks (X-XSS-Protection, CSP)
  - Data leakage (Referrer-Policy)
  - Unwanted features (Permissions-Policy)
  - Cross-origin attacks (COOP, CORP)
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", permissions_policy())
    |> put_resp_header("content-security-policy", content_security_policy())
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> maybe_add_hsts()
  end

  defp permissions_policy do
    "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"
  end

  defp content_security_policy do
    [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline' blob:",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:",
      "font-src 'self'",
      "connect-src 'self'",
      "frame-ancestors 'none'",
      "form-action 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "worker-src 'self' blob:"
    ]
    |> Enum.join("; ")
  end

  defp maybe_add_hsts(conn) do
    if conn.scheme == :https do
      put_resp_header(conn, "strict-transport-security", "max-age=31536000; includeSubDomains")
    else
      conn
    end
  end
end
