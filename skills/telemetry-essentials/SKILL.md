---
name: telemetry-essentials
description: MANDATORY for ALL telemetry, logging, and observability work. Invoke before writing telemetry handlers, Logger calls, or metrics code.
file_patterns:
  - "**/*.ex"
  - "**/*.exs"
auto_suggest: true
---

# Telemetry Essentials

## RULES — Follow these with no exceptions

1. **Use structured logging (`Logger.info("action", key: value)`)** — never string interpolation in log messages; structured logs are searchable and parseable
2. **Attach telemetry handlers in `Application.start/2`** — not in modules that may restart; handler attachment is not idempotent
3. **Use `Ecto.Repo` telemetry events for query monitoring** — don't wrap every query manually; Ecto already emits events
4. **Use `Phoenix.LiveDashboard` in dev/staging** — it's free observability with zero code
5. **Tag telemetry events with metadata (user_id, request_id)** — without correlation IDs, distributed traces are useless
6. **Never log at `:debug` level in production** — it includes query parameters and PII

---

## Structured Logging

Structured logs can be filtered, searched, and aggregated. String-interpolated logs cannot.

**Bad:**
```elixir
# String interpolation — unsearchable, inconsistent format
Logger.info("User #{user.id} created order #{order.id} for $#{order.total}")
Logger.error("Failed to process payment for user #{user.id}: #{inspect(reason)}")
```

**Good:**
```elixir
# Structured logging — searchable, parseable by log aggregators
Logger.info("Order created", user_id: user.id, order_id: order.id, total: order.total)
Logger.error("Payment failed", user_id: user.id, reason: inspect(reason))
```

### Logger Metadata

Set metadata once per request — it's automatically included in all subsequent log calls.

```elixir
# In a Plug (added to your endpoint or router pipeline)
defmodule MyAppWeb.Plugs.RequestMetadata do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    Logger.metadata(
      request_id: conn.assigns[:request_id] || Ecto.UUID.generate(),
      remote_ip: to_string(:inet.ntoa(conn.remote_ip))
    )
    conn
  end
end

# In a LiveView mount
@impl true
def mount(_params, _session, socket) do
  if connected?(socket) do
    Logger.metadata(user_id: socket.assigns.current_user.id)
  end
  {:ok, socket}
end
```

### JSON Logging for Production

```elixir
# config/prod.exs
config :logger, :console,
  format: {LogfmtEx, :format},  # Or Jason-based formatter
  metadata: [:request_id, :user_id, :module, :function]
```

---

## :telemetry Basics

The `:telemetry` library is the standard for metrics in the BEAM ecosystem. Libraries (Ecto, Phoenix, Oban) emit events — you attach handlers.

### Event Structure

```elixir
# An event has: name (list of atoms), measurements (map), metadata (map)
:telemetry.execute(
  [:my_app, :orders, :created],     # event name
  %{count: 1, total_cents: 4999},    # measurements
  %{user_id: user.id, source: :web}  # metadata
)
```

### Attaching Handlers

Always attach in `Application.start/2` — handler attachment is **not idempotent** and modules may restart.

**Bad:**
```elixir
# In a GenServer init — if GenServer restarts, handlers are attached again
defmodule MyApp.MetricsServer do
  def init(_) do
    :telemetry.attach("order-handler", [:my_app, :orders, :created], &handle/4, nil)
    {:ok, %{}}
  end
end
```

**Good:**
```elixir
# In application.ex — runs once at boot
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    MyApp.Telemetry.attach_handlers()

    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

# lib/my_app/telemetry.ex
defmodule MyApp.Telemetry do
  require Logger

  def attach_handlers do
    :telemetry.attach_many("my-app-handlers", [
      [:my_app, :orders, :created],
      [:my_app, :payments, :processed],
      [:my_app, :payments, :failed]
    ], &handle_event/4, nil)
  end

  def handle_event([:my_app, :orders, :created], measurements, metadata, _config) do
    Logger.info("Order created",
      total_cents: measurements.count,
      user_id: metadata.user_id
    )
  end

  def handle_event([:my_app, :payments, :failed], _measurements, metadata, _config) do
    Logger.error("Payment failed",
      user_id: metadata.user_id,
      reason: metadata.reason
    )
  end
end
```

### Telemetry Spans

For timing operations:

```elixir
def process_order(order) do
  :telemetry.span([:my_app, :orders, :process], %{order_id: order.id}, fn ->
    result = do_process(order)
    {result, %{order_id: order.id, status: :completed}}
  end)
end

# Emits two events:
# [:my_app, :orders, :process, :start] — with measurements: %{system_time: ...}
# [:my_app, :orders, :process, :stop]  — with measurements: %{duration: ...}
# [:my_app, :orders, :process, :exception] — if an exception is raised
```

---

## Ecto Telemetry Events

Ecto automatically emits telemetry events for every query. You don't need to instrument queries manually.

### Built-in Events

```elixir
# Ecto emits: [:my_app, :repo, :query]
# Measurements: %{
#   total_time: integer,    # Total time in native units
#   decode_time: integer,   # Time decoding results
#   query_time: integer,    # Time executing the query
#   queue_time: integer,    # Time waiting for a connection
#   idle_time: integer      # Time the connection was idle
# }
# Metadata: %{
#   query: "SELECT ...",
#   source: "users",
#   repo: MyApp.Repo,
#   result: {:ok, %Postgrex.Result{}} | {:error, ...}
# }
```

### Monitoring Slow Queries

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def attach_handlers do
    :telemetry.attach(
      "ecto-slow-query",
      [:my_app, :repo, :query],
      &handle_slow_query/4,
      %{threshold_ms: 100}
    )
  end

  def handle_slow_query(_event, measurements, metadata, %{threshold_ms: threshold}) do
    duration_ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)

    if duration_ms > threshold do
      Logger.warning("Slow query",
        duration_ms: duration_ms,
        source: metadata.source,
        query: metadata.query
      )
    end
  end
end
```

---

## Phoenix Telemetry Events

Phoenix emits events for the request lifecycle.

```elixir
# Request events:
# [:phoenix, :endpoint, :start]
# [:phoenix, :endpoint, :stop]
# [:phoenix, :router_dispatch, :start]
# [:phoenix, :router_dispatch, :stop]

# LiveView events:
# [:phoenix, :live_view, :mount, :start]
# [:phoenix, :live_view, :mount, :stop]
# [:phoenix, :live_view, :handle_event, :start]
# [:phoenix, :live_view, :handle_event, :stop]

# Channel events:
# [:phoenix, :channel_joined]
# [:phoenix, :channel_handled_in]
```

---

## LiveDashboard Setup

Phoenix.LiveDashboard provides free observability with zero code.

```elixir
# mix.exs — add dependency (already included in new Phoenix projects)
{:phoenix_live_dashboard, "~> 0.8"}

# router.ex
import Phoenix.LiveDashboard.Router

scope "/" do
  pipe_through :browser

  # Only in dev/staging — never expose in production without auth
  live_dashboard "/dashboard",
    metrics: MyAppWeb.Telemetry,
    ecto_repos: [MyApp.Repo],
    ecto_psql_extras_options: [long_running_queries: [threshold: "200 milliseconds"]]
end
```

### Custom Metrics for LiveDashboard

```elixir
# lib/my_app_web/telemetry.ex
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix metrics
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration", unit: {:native, :millisecond}),

      # Ecto metrics
      summary("my_app.repo.query.total_time", unit: {:native, :millisecond}),
      summary("my_app.repo.query.queue_time", unit: {:native, :millisecond}),

      # VM metrics
      summary("vm.memory.total", unit: :byte),
      summary("vm.total_run_queue_lengths.total"),

      # Custom business metrics
      counter("my_app.orders.created.count"),
      summary("my_app.payments.processed.duration", unit: {:native, :millisecond})
    ]
  end

  defp periodic_measurements do
    [
      {MyApp.Metrics, :dispatch_queue_depth, []}
    ]
  end
end
```

---

## Custom Business Metrics

Emit telemetry events from your contexts for important business operations.

```elixir
defmodule MyApp.Orders do
  def create_order(attrs) do
    :telemetry.span([:my_app, :orders, :create], %{}, fn ->
      case %Order{}
           |> Order.changeset(attrs)
           |> Repo.insert() do
        {:ok, order} ->
          :telemetry.execute([:my_app, :orders, :created], %{
            count: 1,
            total_cents: order.total_cents
          }, %{user_id: order.user_id})

          {{:ok, order}, %{status: :ok}}

        {:error, changeset} ->
          {{:error, changeset}, %{status: :error}}
      end
    end)
  end
end
```

---

## External Tool Integration

### Prometheus

```elixir
# mix.exs
{:telemetry_metrics_prometheus, "~> 1.1"}

# application.ex children
TelemetryMetricsPrometheus.child_spec(metrics: MyAppWeb.Telemetry.metrics())

# Exposes /metrics endpoint for Prometheus scraping
```

### StatsD / Datadog

```elixir
# mix.exs
{:telemetry_metrics_statsd, "~> 0.7"}

# application.ex children
{TelemetryMetricsStatsd, metrics: MyAppWeb.Telemetry.metrics()}
```

---

## Production Log Levels

```elixir
# config/prod.exs — default to :info
config :logger, level: :info

# config/runtime.exs — allow override for debugging
if config_env() == :prod do
  if log_level = System.get_env("LOG_LEVEL") do
    config :logger, level: String.to_existing_atom(log_level)
  end
end
```

**What each level logs:**
| Level | Includes | Production Use |
|-------|----------|---------------|
| `:debug` | SQL params, internal state | Never (PII risk) |
| `:info` | Requests, business events | Default |
| `:warning` | Recoverable issues | Always |
| `:error` | Failures needing attention | Always |

---

See `deployment-gotchas` skill for production configuration patterns.
See `security-essentials` skill for sensitive data logging rules.
See `otp-essentials` skill for process monitoring patterns.
