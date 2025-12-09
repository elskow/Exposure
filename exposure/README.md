# Exposure

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Environment Variables

### Required (Production)

| Variable | Description |
|----------|-------------|
| `DATABASE_PATH` | Path to SQLite database file (e.g., `/app/data/exposure.db`) |
| `SECRET_KEY_BASE` | Phoenix secret key (generate with `mix phx.gen.secret`) |
| `PHX_HOST` | Your domain (e.g., `gallery.example.com`) |

### Authentication

| Variable | Description | Default |
|----------|-------------|---------|
| `AUTH_MODE` | Authentication mode: `local`, `oidc`, or `both` | `local` |
| `ADMIN_USERS` | Local admin credentials (format: `user:pass,user2:pass2`) | - |

#### OIDC (when `AUTH_MODE` is `oidc` or `both`)

| Variable | Description |
|----------|-------------|
| `OIDC_CLIENT_ID` | OIDC client ID |
| `OIDC_CLIENT_SECRET` | OIDC client secret |
| `OIDC_ISSUER_URL` | OIDC issuer URL for discovery |
| `OIDC_PROVIDER_NAME` | Display name for SSO button (default: `SSO`) |
| `OIDC_ALLOWED_EMAILS` | Comma-separated allowed emails |
| `OIDC_ALLOWED_DOMAINS` | Comma-separated allowed email domains |

### Datadog APM (Optional)

Datadog APM monitoring requires a running Datadog Agent. Tracing is enabled in production by default.

| Variable | Description | Default |
|----------|-------------|---------|
| `DD_AGENT_HOST` | Datadog Agent hostname | `localhost` |
| `DD_TRACE_AGENT_PORT` | Datadog Agent trace port | `8126` |
| `DD_SERVICE` | Service name in Datadog | `exposure` |
| `DD_ENV` | Environment name (e.g., `production`, `staging`) | `production` |

Example:
```bash
export DD_AGENT_HOST=datadog-agent
export DD_ENV=production
export DD_SERVICE=exposure
```

**Features enabled automatically:**
- Distributed tracing (Phoenix requests)
- Database query tracing (Ecto via SpandexEcto)
- Background job tracing (Oban)
- Error tracking
- Log correlation (JSON logs with trace IDs)

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
