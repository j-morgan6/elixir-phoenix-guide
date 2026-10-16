---
name: deployment-gotchas
description: "Use when preparing releases or deployment config — mix phx.gen.release, runtime.exs vs compile-time config, release migrations, PHX_HOST/PHX_SERVER, SSL, Dockerfile order, health checks. Not for logging/metrics (use telemetry-essentials)."
---

# Deployment Gotchas

> Verified against Elixir 1.20, Phoenix 1.8, Ecto 3.14 — October 2026

Not a deployment guide. These are the things that break first Phoenix deploys, each tied to a real incident pattern.

## RULES — Follow these with no exceptions

1. **Start from `mix phx.gen.release --docker`** — it generates `MyApp.Release`, `bin/migrate`, `bin/server` and a Dockerfile in the right build order; don't hand-write them
2. **Environment values go in `runtime.exs`; compile-time settings stay in `config/prod.exs`** — `force_ssl` and anything read with `Application.compile_env` can't be changed at boot
3. **Run migrations with `bin/migrate` before the new code takes traffic, and keep them backward-compatible** — during a rolling deploy the old version runs against the new schema (expand, then contract in a later deploy)
4. **Start the server with `bin/server` (sets `PHX_SERVER=true`) and set `PHX_HOST`** — `runtime.exs` enables the server only when `PHX_SERVER` is set; a wrong host breaks generated URLs and the websocket `check_origin`
5. **Build order is `deps.compile` → `compile` → `assets.deploy` → `release`** — colocated hooks are extracted during `mix compile`, so assets built before compiling miss them
6. **Never hardcode secrets** — read them in `runtime.exs` and fail at boot if missing
7. **Split health checks: liveness never touches the database, readiness does** — and neither returns error details (`inspect(reason)` leaks hostnames)
8. **Behind a load balancer: keep `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, enable database SSL, keep `check_origin`**
9. **Use `config :logger, level: :info` in production** — `:debug` logs query parameters, which contain user data

---

## 1. Generate the Release Files

```bash
mix phx.gen.release --docker
```

It creates:

- `lib/my_app/release.ex` — `migrate/0` and `rollback/2`, runnable without Mix
- `rel/overlays/bin/migrate` — runs `./my_app eval MyApp.Release.migrate`
- `rel/overlays/bin/server` — runs `PHX_SERVER=true exec ./my_app start`
- `Dockerfile` and `.dockerignore` — a multi-stage build pinned to your Elixir/OTP versions

Hand-written `release.ex` files often use `Application.load(@app)`. That returns `{:error, {:already_loaded, _}}` when the app is already loaded. The generator uses the idempotent `Application.ensure_loaded/1`:

```elixir
# lib/my_app/release.ex (generated)
defp load_app do
  # Many platforms require SSL when connecting to the database
  Application.ensure_all_started(:ssl)
  Application.ensure_loaded(@app)
end
```

---

## 2. runtime.exs vs config.exs

**The incident:** `DATABASE_URL` is set correctly in production, but the release connects to the build machine's database, or to none.

**Why:** `config.exs` and `prod.exs` are evaluated when you **build** the release and baked into it. `runtime.exs` is evaluated at **boot**.

<!-- epg:bad -->
```elixir
# config/prod.exs — runs on the build machine
config :my_app, MyApp.Repo, url: System.get_env("DATABASE_URL")
```

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :my_app, MyApp.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
```

The reverse mistake: some settings are read at compile time with `Application.compile_env/3` and can't be changed at boot. Examples are the endpoint's `force_ssl`, `code_reloader` and `debug_errors`, and the generated `:dev_routes`. Set them in `config.exs`/`prod.exs`. If `runtime.exs` sets one to a different value, the release refuses to boot ("the application :my_app has a different value set for key ... during runtime compared to compile time").

---

## 3. Release Migrations and Rolling Deploys

**The incident:** a deploy renames `users.name` to `users.full_name`. For the two minutes when old and new instances both serve traffic, every request on the old instances 500s.

```bash
# In production — no Mix in a release
bin/migrate
# or: bin/my_app eval "MyApp.Release.migrate()"
```

Run it as a pre-deploy step (a release command, init container or job) **before** new instances start. Then the old version briefly runs against the new schema, so every migration must be safe for the code that's already deployed:

| Change | Safe sequence |
|---|---|
| Add a column | Add it as nullable or with a default → deploy the code that writes it → backfill → add `NOT NULL` later |
| Rename a column | Add the new column → write both → backfill → read the new one → drop the old one in a later deploy |
| Drop a column | Stop reading it (remove it from the schema) → deploy → drop it in the next deploy |
| Add an index on a big table | `create index(..., concurrently: true)` with `@disable_ddl_transaction true` and `@disable_migration_lock true` |

The exact migration code for each row (including `NOT NULL` without a full-table scan and `lock_timeout`) is in the `ecto-migrations-safety` skill.

Don't run migrations from `Application.start/2`. Every node would race to run them on boot.

---

## 4. PHX_SERVER, PHX_HOST and Networking

**The incident:** the release starts and the health check passes, but nothing listens on the port. Or emails link to `https://example.com`.

The generated `runtime.exs` already does the right thing:

```elixir
# config/runtime.exs (generated)
if System.get_env("PHX_SERVER") do
  config :my_app, MyAppWeb.Endpoint, server: true
end

if config_env() == :prod do
  host = System.get_env("PHX_HOST") || "example.com"

  config :my_app, MyAppWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # IPv6 dual-stack: accepts IPv4 and IPv6 on all interfaces
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}]
end
```

- **Start with `bin/server`**, which sets `PHX_SERVER=true`. `bin/my_app start` alone boots the app without the HTTP listener. Keep the conditional rather than an unconditional `server: true`, so you can still boot a node without the listener (a worker-only node, or a `bin/my_app start_iex` maintenance console).
- **Set `PHX_HOST`**. The fallback `"example.com"` produces wrong links and makes `check_origin` reject every websocket connection.
- **`ECTO_IPV6=true`** makes the Repo connect over IPv6 (`socket_options: [:inet6]`). Fly.io's private network, for example, is IPv6-only.
- **`DNS_CLUSTER_QUERY`** feeds the generated `{DNSCluster, query: ...}` child, which connects nodes for PubSub and Presence across instances. Without it each node is alone and broadcasts don't cross instances.

---

## 5. Docker Build Order

**The incident:** CSS and JS 404, or LiveView colocated hooks are missing from `app.js`.

The generated Dockerfile builds in this order. Keep it:

```dockerfile
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile
RUN mix assets.setup
COPY priv priv
COPY lib lib
# Compile first: colocated hooks/JS are extracted at compile time
RUN mix compile
COPY assets assets
RUN mix assets.deploy
# runtime.exs last: changing it doesn't invalidate the compile layers
COPY config/runtime.exs config/
COPY rel rel
RUN mix release
```

`mix assets.deploy` runs `tailwind` and `esbuild` with `--minify`, then `phx.digest`, which writes the `priv/static/cache_manifest.json` that `prod.exs` points the endpoint at. Compiling first matters for CSS too: `app.css` imports the `phoenix-colocated` CSS that `mix compile` writes (see the `phoenix-tailwind-daisyui` skill).

---

## 6. Never Hardcode Secrets

<!-- epg:bad -->
```elixir
# config/prod.exs — in git history forever, baked into the release
config :my_app, MyAppWeb.Endpoint, secret_key_base: "actual_secret_key_here"
```

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :my_app, MyAppWeb.Endpoint, secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
```

`fetch_env!` crashes at boot with a clear message. `get_env` returns `nil` and fails later in a confusing place. Generate a value with `mix phx.gen.secret`.

---

## 7. Behind a Load Balancer: TLS, Database SSL, Origins

- **HTTPS redirect and HSTS**: the generated `config/prod.exs` has `force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost", "127.0.0.1"]]]`. `rewrite_on` makes the app trust the proxy's `x-forwarded-proto`; without it every request looks like HTTP and you get a redirect loop. If the load balancer probes over plain HTTP, add the health paths: `exclude: [paths: ["/health/live", "/health/ready"], hosts: [...]]`.
- **Database SSL**: the generated `runtime.exs` leaves `# ssl: true` commented out. With Postgrex 0.21+, `ssl: true` verifies the server certificate against the OS CA store (`:public_key.cacerts_get()`). If you pass a keyword list instead (`ssl: [...]`), add `cacerts: :public_key.cacerts_get()` (or `cacertfile:` for a provider's private CA) yourself: the list form doesn't add CA certificates.
- **WebSocket origin**: keep `check_origin` on; it compares the `Origin` header with `url: [host: ...]` (so `PHX_HOST` must be right), and several domains are listed explicitly. See the `phoenix-channels-essentials` skill.

---

## 8. Health Endpoints

**The incident:** a database blip makes every instance fail its health check. The orchestrator restarts the whole fleet, and the reconnect storm makes the outage longer.

Keep two checks with different jobs. **Liveness** ("is this BEAM alive?") must not touch the database. Failing it restarts the instance. **Readiness** ("can this instance serve?") queries the database. Failing it takes the instance out of rotation without restarting it.

```elixir
# router.ex — outside :browser (no session/CSRF needed)
scope "/health", MyAppWeb do
  pipe_through :api

  get "/live", HealthController, :live
  get "/ready", HealthController, :ready
end
```

```elixir
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  alias Ecto.Adapters.SQL

  require Logger

  def live(conn, _params), do: send_resp(conn, 200, "ok")

  def ready(conn, _params) do
    case SQL.query(MyApp.Repo, "SELECT 1", [], timeout: 1_000) do
      {:ok, _} ->
        json(conn, %{status: "ok"})

      {:error, reason} ->
        # Details go to the log, never to the (often public) response
        Logger.error("Readiness check failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable"})
    end
  end
end
```

Point the liveness probe at `/health/live` and the readiness probe (or the load balancer's target health check) at `/health/ready`.

---

## 9. Production Log Level

**The incident:** log storage costs spike, and the logs contain full SQL parameters: emails and addresses.

The generated `config/prod.exs` sets `config :logger, level: :info`. Keep it. To allow a temporary override without a rebuild:

```elixir
# config/runtime.exs
if config_env() == :prod do
  level =
    case System.get_env("LOG_LEVEL") do
      "debug" -> :debug
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end

  config :logger, level: level
end
```

At runtime on a live node you can also call `Logger.configure(level: :debug)` from `bin/my_app remote`, then set it back.

---

## 10. Oban in Releases

- Oban's tables come from an ordinary Ecto migration that calls `Oban.Migrations.up/1`, so `bin/migrate` covers them. Oban upgrades that need a new migration version go through the same path.
- To run jobs only on some nodes (for example worker nodes rather than web nodes), keep the queue list in `config.exs` and switch it off per node in `runtime.exs` with `queues: false`. The node starts no queues and can still insert jobs.
- Don't use `queues: []` for this: config files deep-merge keyword lists, and `[]` is an empty keyword list, so `[default: 10]` from `config.exs` survives the merge. For the same reason, a `queues: [...]` list in `runtime.exs` is merged into the `config.exs` list, not substituted for it.

```elixir
# config/runtime.exs
if config_env() == :prod and System.get_env("OBAN_QUEUES") == "false" do
  config :my_app, Oban, queues: false
end
```

See the `oban-essentials` skill for Oban configuration.

---

## Not Covered (Intentionally)

Platform specifics (Fly.io, Gigalixir, Render, Kubernetes manifests, CI pipelines) are covered in platform docs and the Phoenix deployment guides.

---

See the `telemetry-essentials` skill for production logging and observability.
See the `security-essentials` skill for secrets, HTTPS and cookie settings.
