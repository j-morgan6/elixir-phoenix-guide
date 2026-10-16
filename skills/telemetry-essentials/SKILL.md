---
name: telemetry-essentials
description: "Use when adding logging, metrics, or instrumentation — Logger metadata, :telemetry handlers, Telemetry.Metrics tags, Ecto/Phoenix events, LiveDashboard, OpenTelemetry. Not for deployment config (use deployment-gotchas)."
---

# Telemetry Essentials

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Put values you'll filter on in Logger metadata; a human-readable message may interpolate** — `Logger.info("Order #{order.id} created", order_id: order.id)`; `require Logger` first, and list the metadata keys in the formatter config or they're dropped
2. **Configure log output with `config :logger, :default_formatter` (or `:default_handler` for a JSON formatter)** — `config :logger, :console` is ignored when `:default_formatter` is set, which Phoenix 1.8's `config.exs` does
3. **Don't overwrite `request_id`** — `Plug.RequestId` (in every generated endpoint) already sets it as Logger metadata; it is not in `conn.assigns`
4. **Attach handlers once at boot, with `&__MODULE__.handle_event/4` and a catch-all clause** — a handler that raises is detached permanently and silently; a local capture (`&handle_event/4`) makes telemetry warn about a performance penalty
5. **Use the events Ecto, Phoenix and Oban already emit** — don't wrap queries manually; of Ecto's query measurements only `total_time` is always present, so read the others with `Map.get/2`
6. **Metric tags must have low cardinality** — route, status, queue, `source` yes; `user_id`, `request_id`, email never. Per-user ids belong in log metadata and traces
7. **If the project has its own telemetry wrapper or event catalog, use it** instead of calling `:telemetry.execute/3` directly
8. **Logger metadata is per process** — `Task`, `GenServer` and LiveView processes don't inherit it; pass it on explicitly
9. **LiveDashboard stays inside the generated `dev_routes` block, or behind admin auth** — never in a scope with only `:browser`
10. **Never log at `:debug` in production** — it includes query parameters (see the `deployment-gotchas` skill)

---

## Logging

Metadata is what log tools index and filter on. The message is for humans and may interpolate.

<!-- epg:bad -->
```elixir
# Nothing to filter on, and inspect(user) dumps the whole struct
Logger.info("User #{inspect(user)} created order")
```

```elixir
require Logger

Logger.info("Order #{order.id} created", order_id: order.id, user_id: order.user_id)
Logger.error("Payment failed: #{inspect(reason)}", order_id: order.id, reason: inspect(reason))
```

Metadata keys not listed in the formatter config are silently dropped:

```elixir
# config/config.exs — Phoenix 1.8 generates this block; extend the list
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :user_id, :order_id]
```

### JSON logs in production

[logger_json](https://hex.pm/packages/logger_json) 7 plugs into Elixir's default handler:

```elixir
# mix.exs
{:logger_json, "~> 7.0"}

# config/runtime.exs
if config_env() == :prod do
  config :logger, :default_handler,
    formatter: LoggerJSON.Formatters.Basic.new(metadata: [:request_id, :user_id, :order_id])
end
```

`Basic.new/1` is only available in `runtime.exs` (deps are loaded by then). In `config.exs`/`prod.exs` use the tuple form `{LoggerJSON.Formatters.Basic, metadata: [...]}`. Formatters for Datadog, Google Cloud and Elastic exist alongside `Basic`.

<!-- epg:bad -->
```elixir
# Ignored: :console is copied to :default_formatter only when :default_formatter
# is unset, and Phoenix 1.8's config.exs sets it
config :logger, :console, format: "$message\n", metadata: [:request_id]
```

### Per-request and per-user metadata

`request_id` is already set by `Plug.RequestId`. Add the user once the scope is known, in a router plug and in a LiveView `on_mount` hook. A LiveView runs in its own process, so plug metadata doesn't reach it.

```elixir
# router.ex — after :fetch_current_scope_for_user in the :browser pipeline
plug :put_user_log_metadata

defp put_user_log_metadata(conn, _opts) do
  with %{user: %{id: user_id}} <- conn.assigns[:current_scope] do
    Logger.metadata(user_id: user_id)
  end

  conn
end
```

```elixir
defmodule MyAppWeb.LogMetadata do
  def on_mount(:default, _params, _session, socket) do
    with %{user: %{id: user_id}} <- socket.assigns[:current_scope] do
      Logger.metadata(user_id: user_id)
    end

    {:cont, socket}
  end
end

# router.ex — after the hook that assigns current_scope
live_session :require_authenticated_user,
  on_mount: [{MyAppWeb.UserAuth, :require_authenticated}, MyAppWeb.LogMetadata] do
  # live routes
end
```

`Logger.metadata/1` is a plain function, so it needs no `require Logger` (an unused `require` is a warning).

### Spawned processes lose metadata

```elixir
metadata = Logger.metadata()

Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  Logger.metadata(metadata)
  deliver_webhook(event)
end)
```

The same applies to Oban jobs: put the ids you need in the job args and set metadata in `perform/1`. OpenTelemetry carries trace context across processes, but only in code instrumented to propagate it.

---

## :telemetry Basics

```elixir
# name (list of atoms), measurements (map), metadata (map)
:telemetry.execute([:my_app, :orders, :created], %{count: 1, total_cents: 4999}, %{source: :web})
```

### Attaching handlers

```elixir
# lib/my_app/application.ex
@impl true
def start(_type, _args) do
  MyApp.TelemetryHandlers.attach()

  children = [
    MyAppWeb.Telemetry,
    MyApp.Repo,
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

```elixir
defmodule MyApp.TelemetryHandlers do
  require Logger

  @events [
    [:my_app, :orders, :created],
    [:my_app, :payments, :failed]
  ]

  def attach do
    :telemetry.attach_many("my-app-handlers", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:my_app, :orders, :created], measurements, metadata, _config) do
    Logger.info("Order created", total_cents: measurements.total_cents, source: metadata.source)
  end

  def handle_event([:my_app, :payments, :failed], _measurements, metadata, _config) do
    Logger.error("Payment failed: #{inspect(metadata.reason)}", order_id: metadata.order_id)
  end

  # Catch-all: an event added to @events without a clause must not crash the handler,
  # since telemetry would then detach it for every event in the list
  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
```

Handlers run synchronously **in the process that emitted the event**. Keep them fast, and send slow work (HTTP calls, heavy aggregation) to another process. `:telemetry.attach/4` with an existing handler id returns `{:error, :already_exists}`.

### Spans

```elixir
def process_order(order) do
  :telemetry.span([:my_app, :orders, :process], %{order_id: order.id}, fn ->
    result = do_process(order)
    {result, %{order_id: order.id, status: elem(result, 0)}}
  end)
end

# Emits [:my_app, :orders, :process, :start]     — %{system_time: ..., monotonic_time: ...}
#       [:my_app, :orders, :process, :stop]      — %{duration: ..., monotonic_time: ...}
#       [:my_app, :orders, :process, :exception] — if the function raises, throws or exits
```

---

## Ecto Telemetry

Each repo emits `[:my_app, :repo, :query]` (the prefix comes from the repo's `:telemetry_prefix`). Measurements are in `:native` units: `total_time` is always present, while `query_time`, `queue_time`, `decode_time` and `idle_time` are **omitted** when unknown. Metadata includes `:query`, `:source` (may be `nil`), `:repo`, `:result`, and `:params`. The params can contain personal data, so don't log them.

```elixir
defmodule MyApp.SlowQueryLogger do
  require Logger

  def attach do
    :telemetry.attach("slow-queries", [:my_app, :repo, :query], &__MODULE__.handle_event/4, %{
      threshold_ms: 100
    })
  end

  def handle_event(_event, measurements, metadata, %{threshold_ms: threshold}) do
    total_ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)

    if total_ms > threshold do
      queue_ms = System.convert_time_unit(Map.get(measurements, :queue_time, 0), :native, :millisecond)

      Logger.warning("Slow query (#{total_ms}ms) on #{metadata.source || "unknown"}",
        duration_ms: total_ms,
        queue_ms: queue_ms,
        source: metadata.source,
        query: metadata.query
      )
    end
  end
end
```

A high `queue_ms` means the pool is too small or connections are held too long. A high query time means the query itself needs work. To act on a slow query (EXPLAIN, indexes, preloads), see the `ecto-queries-performance` skill.

---

## Phoenix Events

```elixir
# [:phoenix, :endpoint, :start | :stop]
# [:phoenix, :router_dispatch, :start | :stop | :exception]   — metadata has :route
# [:phoenix, :live_view, :mount | :handle_params | :handle_event, :start | :stop | :exception]
# [:phoenix, :live_component, :handle_event, :start | :stop | :exception]
# [:phoenix, :socket_connected], [:phoenix, :channel_joined], [:phoenix, :channel_handled_in]
```

---

## Metrics (`Telemetry.Metrics`)

Phoenix generates `MyAppWeb.Telemetry` with a `metrics/0` list. Add to it rather than writing a second module.

```elixir
def metrics do
  [
    summary("phoenix.router_dispatch.stop.duration",
      tags: [:route],
      unit: {:native, :millisecond}
    ),

    # tag_values derives a low-cardinality tag from metadata
    counter("my_app.orders.process.stop.duration",
      tags: [:status],
      tag_values: fn metadata -> %{status: Map.get(metadata, :status, :unknown)} end
    ),

    # keep records only the events you care about
    summary("my_app.repo.query.total_time",
      tags: [:source],
      unit: {:native, :millisecond},
      keep: fn metadata -> metadata[:source] != "oban_jobs" end
    ),

    last_value("vm.memory.total", unit: {:byte, :kilobyte})
  ]
end
```

Each distinct tag combination is a separate time series. Tagging by `user_id` or `request_id` creates one series per user or request. That makes the reporter's memory grow without bound and the metrics bill with it.

**Reporters** are children that take `metrics: MyAppWeb.Telemetry.metrics()`:

- [telemetry_metrics_prometheus](https://hex.pm/packages/telemetry_metrics_prometheus): `{TelemetryMetricsPrometheus, metrics: metrics()}` serves `/metrics` on port 9568. It doesn't support `summary`; use `distribution` (histogram buckets) instead.
- [telemetry_metrics_statsd](https://hex.pm/packages/telemetry_metrics_statsd): `{TelemetryMetricsStatsd, metrics: metrics()}`, for Datadog and StatsD agents.

---

## Tracing (OpenTelemetry)

For distributed traces, add `opentelemetry` and `opentelemetry_exporter` (configure the exporter for your backend), then call the instrumentation setups in `Application.start/2` before the supervisor starts:

```elixir
OpentelemetryBandit.setup()
OpentelemetryPhoenix.setup(adapter: :bandit)
OpentelemetryEcto.setup([:my_app, :repo])
OpentelemetryOban.setup()
```

These come from `opentelemetry_bandit`, `opentelemetry_phoenix`, `opentelemetry_ecto` and `opentelemetry_oban`. Per-user ids go on spans as attributes, never as metric tags. For outbound HTTP spans (`OpentelemetryReq`) and per-API Req metrics, see the `http-clients-req` skill.

---

## LiveDashboard

Phoenix generates it inside the `dev_routes` block, which only compiles in dev. Keep it there:

```elixir
# router.ex (generated)
if Application.compile_env(:my_app, :dev_routes) do
  import Phoenix.LiveDashboard.Router

  scope "/dev" do
    pipe_through :browser

    live_dashboard "/dashboard", metrics: MyAppWeb.Telemetry
    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end
end
```

To use it in production, mount it behind authentication. Use your own admin plug, or `Plug.BasicAuth` over HTTPS:

```elixir
import Phoenix.LiveDashboard.Router

pipeline :admin_basic_auth do
  plug :dashboard_auth
end

scope "/admin" do
  pipe_through [:browser, :admin_basic_auth]

  live_dashboard "/dashboard", metrics: MyAppWeb.Telemetry, ecto_repos: [MyApp.Repo]
end

defp dashboard_auth(conn, _opts) do
  Plug.BasicAuth.basic_auth(conn,
    username: System.fetch_env!("DASHBOARD_USER"),
    password: System.fetch_env!("DASHBOARD_PASSWORD")
  )
end
```

It exposes process state, ETS contents and request logs. Anyone who can reach it can read data from every user.

---

## Testing Telemetry

`:telemetry_test.attach_event_handlers/2` sends each matching event to the test process:

```elixir
test "processing an order emits a stop event", %{scope: scope} do
  ref = :telemetry_test.attach_event_handlers(self(), [[:my_app, :orders, :process, :stop]])
  order = order_fixture(scope)

  Orders.process_order(order)

  assert_received {[:my_app, :orders, :process, :stop], ^ref, %{duration: _},
                   %{order_id: order_id, status: :ok}}

  assert order_id == order.id
end
```

Handlers are global. With `async: true`, events from other tests can arrive too, so match on metadata that identifies your test's data (`order_id` above).

---

See the `deployment-gotchas` skill for production log levels and configuration.
See the `security-essentials` skill for what must never be logged.
See the `otp-essentials` skill for process supervision.
