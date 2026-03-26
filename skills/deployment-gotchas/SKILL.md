---
name: deployment-gotchas
description: MANDATORY for deployment and release configuration. Invoke before modifying config/, rel/, or Dockerfile.
file_patterns:
  - "**/config/*.exs"
  - "**/rel/**"
  - "**/Dockerfile"
  - "**/docker-compose*.yml"
auto_suggest: true
---

# Deployment Gotchas

Not a deployment guide — these are the 7 things that break every first Phoenix deploy. Every rule maps to a real production incident pattern.

## RULES — Follow these with no exceptions

1. **Use `runtime.exs` for secrets and URLs** — `config.exs`/`prod.exs` are compiled into the release and cannot read env vars at boot
2. **Run migrations via release commands (`bin/migrate`)** — `mix` is not available in production releases
3. **Set `PHX_HOST` and `PHX_SERVER=true`** — without these, URL generation breaks and the server won't start
4. **Run `mix assets.deploy` before building the release** — forgetting this means no CSS/JS in production
5. **Never hardcode secrets** — use `System.get_env!/1` in `runtime.exs` (the `!` crashes on boot if missing, which is what you want)
6. **Add a `/health` endpoint that queries the database** — load balancers need it, and a 200-only check hides DB connection failures
7. **Use `config :logger, level: :info` in production** — `:debug` logs query parameters including user data

---

## 1. runtime.exs vs config.exs

**The incident:** App deploys fine but uses the wrong database URL. `DATABASE_URL` was set correctly in the environment, but the release ignores it.

**Why:** `config.exs` and `prod.exs` are evaluated at **compile time** and baked into the release. `runtime.exs` is evaluated at **boot time** and can read environment variables.

**Bad:**
```elixir
# config/prod.exs — compiled into release, cannot read env vars at boot
config :my_app, MyApp.Repo,
  url: System.get_env("DATABASE_URL")  # Always nil in release!
```

**Good:**
```elixir
# config/runtime.exs — evaluated at boot, reads env vars correctly
if config_env() == :prod do
  database_url = System.get_env!("DATABASE_URL")

  config :my_app, MyApp.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
```

**Rule of thumb:** If the value comes from the environment, it goes in `runtime.exs`. If it's a static setting, it goes in `config.exs`.

---

## 2. Release Migrations

**The incident:** Deploy succeeds but the app crashes on boot because new columns don't exist. Developer tries `mix ecto.migrate` on the server — `mix: command not found`.

**Why:** Production releases don't include Mix or the Elixir compiler. Migrations must be run via release commands.

**Bad:**
```bash
# mix is not available in production releases
ssh prod-server "cd /app && mix ecto.migrate"
```

**Good:**
```elixir
# lib/my_app/release.ex
defmodule MyApp.Release do
  @app :my_app

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
```

```bash
# Run migrations in production
bin/my_app eval "MyApp.Release.migrate()"

# Or via rel/overlays if configured
bin/migrate
```

---

## 3. PHX_HOST and PHX_SERVER

**The incident:** Deploy succeeds, health check passes, but all URLs in emails and redirects point to `localhost:4000`. Or worse — the server doesn't start at all.

**Why:** Without `PHX_SERVER=true`, the Phoenix endpoint doesn't start its HTTP listener. Without `PHX_HOST`, URL helpers generate `localhost` URLs.

**Bad:**
```elixir
# config/runtime.exs — missing host and server config
config :my_app, MyAppWeb.Endpoint,
  url: [host: "localhost"],  # Wrong in production!
  http: [port: 4000]
  # Server doesn't start without server: true
```

**Good:**
```elixir
# config/runtime.exs
if config_env() == :prod do
  host = System.get_env!("PHX_HOST")
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :my_app, MyAppWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    server: true  # Or set PHX_SERVER=true env var
end
```

---

## 4. Asset Deployment

**The incident:** App deploys, pages load, but CSS/JS are missing. The page is unstyled raw HTML.

**Why:** Assets must be compiled and digested before the release is built. The release bundles `priv/static` — if assets aren't there at build time, they won't be in the release.

**Bad:**
```dockerfile
# Dockerfile — builds release without compiling assets
RUN mix release
```

**Good:**
```dockerfile
# Dockerfile — correct order
RUN mix assets.deploy
RUN mix release
```

```bash
# Manual build order
mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy  # Must come before release
MIX_ENV=prod mix release
```

**What `mix assets.deploy` does:**
1. Runs `tailwind` and `esbuild` to compile CSS/JS
2. Runs `phx.digest` to fingerprint files for cache busting
3. Generates `cache_manifest.json` for the endpoint to serve

---

## 5. Never Hardcode Secrets

**The incident:** Secret key leaks into git history via `config/prod.exs`. Rotating it requires a new release.

**Why:** Secrets in compiled config are baked into the release binary and visible in version control.

**Bad:**
```elixir
# config/prod.exs — secret in source code
config :my_app, MyAppWeb.Endpoint,
  secret_key_base: "actual_secret_key_here_in_git_history"
```

**Good:**
```elixir
# config/runtime.exs — read from environment, crash if missing
if config_env() == :prod do
  secret_key_base = System.get_env!("SECRET_KEY_BASE")

  config :my_app, MyAppWeb.Endpoint,
    secret_key_base: secret_key_base
end
```

**Why `get_env!` (with bang):** If the secret is missing, the app crashes immediately on boot with a clear error. Without the bang, it starts with `nil` and fails later with a confusing error.

```bash
# Generate a secret
mix phx.gen.secret

# Set in environment (never in source)
export SECRET_KEY_BASE="generated_secret_here"
```

---

## 6. Health Endpoints

**The incident:** Load balancer reports the app is healthy, but users see 500 errors. The app boots fine but can't connect to the database.

**Why:** A simple `200 OK` endpoint proves the HTTP server started but nothing else. A health check that queries the database proves the full stack works.

**Bad:**
```elixir
# Just proves the server started
get "/health", PageController, :health

def health(conn, _params) do
  send_resp(conn, 200, "OK")
end
```

**Good:**
```elixir
# router.ex
get "/health", HealthController, :check

# lib/my_app_web/controllers/health_controller.ex
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  def check(conn, _params) do
    case Ecto.Adapters.SQL.query(MyApp.Repo, "SELECT 1") do
      {:ok, _} ->
        json(conn, %{status: "ok", database: "connected"})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", database: inspect(reason)})
    end
  end
end
```

**Configure your load balancer** to hit `/health` and expect a 200. If the database goes down, the health check fails and the load balancer stops routing traffic.

---

## 7. Production Log Level

**The incident:** App runs fine but storage costs spike. Investigation reveals debug logs are writing gigabytes per day, including full SQL queries with user data (emails, addresses).

**Why:** Ecto logs all queries at `:debug` level, including query parameters. In production, this means PII in your logs.

**Bad:**
```elixir
# config/prod.exs
config :logger, level: :debug  # Logs everything including query params
```

**Good:**
```elixir
# config/prod.exs
config :logger, level: :info

# config/runtime.exs — allow override for debugging
if config_env() == :prod do
  log_level =
    case System.get_env("LOG_LEVEL") do
      "debug" -> :debug
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end

  config :logger, level: log_level
end
```

**What each level includes:**
- `:debug` — SQL queries with parameters, internal state, PII risk
- `:info` — Request lifecycle, business events (recommended for production)
- `:warning` — Recoverable problems
- `:error` — Failures requiring attention

---

## Not Covered (Intentionally)

This skill does not cover platform-specific deployment:
- Docker/Dockerfile patterns → see official Phoenix deployment guides
- Fly.io, Gigalixir, Render setup → see platform documentation
- Kubernetes manifests → see your infra team's docs
- CI/CD pipeline configuration → project-specific

These are deployment-platform docs, not Phoenix-specific gotchas.

---

See `telemetry-essentials` skill for production logging and observability patterns.
See `security-essentials` skill for secrets management and dependency auditing.
