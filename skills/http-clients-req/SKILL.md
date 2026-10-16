---
name: http-clients-req
description: "Use when calling external HTTP APIs with Req — client modules, Req.new options, retries and Retry-After, timeouts, Finch pools, idempotency keys, Req.Test stubs, SSRF-safe redirects. Not for Oban job structure (use oban-essentials) or serving JSON APIs (use phoenix-json-api)."
---

# HTTP Clients with Req

> Verified against Elixir 1.20, Phoenix 1.8, Req 0.7, Finch 0.24 — October 2026

## RULES — Follow these with no exceptions

1. **One client module per external API.** Build the `%Req.Request{}` in a private function from runtime config (`Application.fetch_env!/2`), never in a module attribute. Merge test-only options (`plug:`) from config, and return domain values (`{:ok, celsius}`), not `%Req.Response{}`.
2. **Match every outcome of `Req.request/2`:** each status you expect, a catch-all `{:ok, %Req.Response{status: status}}`, and `{:error, exception}`. 4xx/5xx responses arrive as `{:ok, response}`, and `Req.get!/2` doesn't raise on them either. Use bang functions only where a crash is fine (scripts, seeds, mix tasks).
3. **Know the default retry.** `retry: :safe_transient` retries GET/HEAD up to 3 times on 408/429/500/502/503/504 and on transport timeouts or refused/closed connections. It sleeps in the calling process and obeys `Retry-After` with no upper limit. Cap that delay, and lower `max_retries` on user-facing paths.
4. **`retry: false` inside Oban workers.** Oban already retries the job with backoff; Req retries on top multiply the attempts and hold the queue slot while they sleep.
5. **Retry POST/PUT/PATCH only with an idempotency key** built from the business record (`"order-#{id}-charge"`), so it stays the same across Req retries and Oban attempts. Then `retry: :transient` is safe.
6. **Set every timeout on purpose.** Connect (5 s by default), `receive_timeout` (15 s per read), `request_timeout` (total time, new in 0.7), and `finch: [pool_timeout: ...]`. Never block a LiveView event handler on a slow API: use `start_async`.
7. **Expect bodies of any shape.** `json:` encodes with Jason. Responses are decoded by `content-type` into maps with string keys. A malformed JSON body is `{:error, %Jason.DecodeError{}}`, and an HTML error page from a proxy stays a binary.
8. **Never fetch a user-supplied URL without a host allowlist and `redirect: false`.** On a redirect to another host, Req drops only `authorization`, so custom API-key headers go along. Never log request headers or bodies, and never use `verify: :verify_none`.
9. **Test with `plug: {Req.Test, MyApp.Client}` and `retry: false` in `config/test.exs`.** Use Mox only at a behaviour boundary, when callers shouldn't see HTTP at all.
10. **Use a named Finch pool only for pool needs** (size, HTTP/2, per-host config). Pass it as `finch: [name: MyApp.Finch]` (the 0.7 form) and put connect options in the pool config: combining `finch:` with `connect_options:` raises.

---

## The client module

```elixir
defmodule MyApp.Weather do
  @moduledoc "Client for the Example Weather API."

  @doc "Current temperature in °C. `opts` are extra Req options, e.g. `retry: false` in Oban workers."
  def current(city, opts \\ []) when is_binary(city) do
    case Req.request(new(), [url: "/v1/current", params: [city: city]] ++ opts) do
      {:ok, %Req.Response{status: 200, body: %{"celsius" => celsius}}} -> {:ok, celsius}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: 429}} -> {:error, :rate_limited}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_response, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp new do
    config = Application.fetch_env!(:my_app, __MODULE__)

    Req.new(
      base_url: Keyword.fetch!(config, :base_url),
      auth: {:bearer, Keyword.fetch!(config, :api_key)},
      receive_timeout: 5_000,
      max_retries: 2
    )
    |> Req.merge(Keyword.get(config, :req_options, []))
  end
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Weather, base_url: "https://api.weather.example"

# config/runtime.exs: secrets are read at boot, not at compile time
if config_env() == :prod do
  config :my_app, MyApp.Weather, api_key: System.fetch_env!("WEATHER_API_KEY")
end

# config/test.exs
config :my_app, MyApp.Weather,
  api_key: "test-key",
  req_options: [plug: {Req.Test, MyApp.Weather}, retry: false]
```

- **Build the struct per call.** It's cheap and does no I/O; connections live in Finch pools and are reused. A module attribute would be evaluated at compile time, before `runtime.exs` runs.
- **Option names are validated.** `Req.new(bas_url: ...)` raises `ArgumentError` ("Did you mean :base_url?"). Custom options need `Req.Request.register_options/2` (see the [reference](reference.md)).
- **Merging:** `Req.merge/2` and per-call options merge `headers` and `params` and override everything else. Options passed later win, so a caller's `retry: false` beats the client default.
- **The `{:error, exception}` side** is usually `%Req.TransportError{reason: :timeout | :econnrefused | :closed | ...}`, but can also be `%Req.HTTPError{}`, `%Req.TooManyRedirectsError{}` or `%Jason.DecodeError{}`.
- **Rotating tokens:** `auth: fn -> {:bearer, MyApp.Tokens.fetch!()} end` is evaluated on every attempt. So is `{mod, fun, args}`.
- **Version check:** Phoenix 1.8 generates `{:req, "~> 0.5"}`. A fresh `mix deps.get` resolves that to 0.7.x, but an older `mix.lock` may still pin 0.5. Several options changed; see [Upgrading from 0.5](#upgrading-from-req-05).

## Retries

| | `retry: :safe_transient` (default) |
|---|---|
| Methods | GET, HEAD (`:transient` retries every method) |
| Responses | 408, 429, 500, 502, 503, 504 |
| Exceptions | `Req.TransportError` with `:timeout`, `:econnrefused`, `:closed`; HTTP/2 `:unprocessed`, `:pool_not_available` |
| Attempts | `max_retries: 3`, so up to 4 requests in total |
| Delay | exponential with jitter (~1 s, 2 s, 4 s); on 429/503 the `Retry-After` value (seconds or HTTP date), **with no cap** |

- The delay is a `Process.sleep/1` in the caller. A `Retry-After: 3600` freezes a controller request or a LiveView for an hour.
- **Setting `retry_delay` makes Req ignore `Retry-After`** (changed in 0.7). To keep honouring the header with a ceiling, pass a 2-arity `retry` function that returns `{:delay, ms}`.
- Retries log at `:warning` by default. Use `retry_log_level: false` to silence them, or `:debug`.

```elixir
# In the client: Req.new(..., retry: &retry?/2)
# Same policy as :safe_transient, but caps Retry-After at 5 s
defp retry?(%Req.Request{method: method}, response_or_exception) when method in [:get, :head] do
  case response_or_exception do
    %Req.Response{status: status} = response when status in [429, 503] ->
      {:delay, min(Req.Response.get_retry_after(response) || 1_000, 5_000)}

    %Req.Response{status: status} ->
      status in [408, 500, 502, 504]

    %Req.TransportError{reason: reason} ->
      reason in [:timeout, :econnrefused, :closed]

    _other ->
      false
  end
end

defp retry?(_request, _response_or_exception), do: false
```

`Req.Response.get_retry_after/1` returns **milliseconds**, even though its docs say seconds. A function that returns `{:delay, ms}` raises if `retry_delay` is also set; returning `true` uses the default backoff.

### Inside Oban workers

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: %{"city" => city}}) do
  case MyApp.Weather.current(city, retry: false) do
    {:ok, celsius} -> MyApp.Forecasts.record_reading(city, celsius)
    {:error, :not_found} -> {:cancel, :unknown_city}
    {:error, reason} -> {:error, reason}
  end
end
```

Oban backs off between attempts and keeps the job's history. Snoozing on 429 and `timeout/1` are covered in the `oban-essentials` skill.

## POSTs and idempotency keys

```elixir
def create_charge(%Order{id: order_id, total_cents: cents}, opts \\ []) do
  request_opts = [
    url: "/v1/charges",
    json: %{amount: cents, currency: "eur", reference: order_id},
    # Same key on every attempt, including Oban retries
    headers: [{"idempotency-key", "order-#{order_id}-charge"}]
  ]

  case Req.post(new(), Keyword.merge(request_opts, opts)) do
    {:ok, %Req.Response{status: status, body: %{"id" => charge_id}}} when status in [200, 201] ->
      {:ok, charge_id}

    {:ok, %Req.Response{status: 422, body: %{"error" => message}}} ->
      {:error, {:rejected, message}}

    {:ok, %Req.Response{status: status}} ->
      {:error, {:unexpected_response, status}}

    {:error, exception} ->
      {:error, exception}
  end
end

# new/0 for this API sets `retry: :transient`, safe only because every request carries a key
```

- A timeout doesn't mean the server didn't act. Without a key, retrying a POST can charge twice.
- **Never generate the key inside a Req step.** Req re-runs every request step on each retry, so a fresh UUID there changes between attempts. If the record has no natural id, generate the key once and store it on the row before the first attempt.
- The header name and semantics come from the provider (Stripe-style `Idempotency-Key` is common). Check how long they keep keys.

## Timeouts

| Option | Default | Bounds |
|---|---|---|
| `connect_options: [timeout: ms]` | 5_000 (Finch's default; Req's docs say 30 s) | TCP + TLS connect |
| `receive_timeout: ms` | 15_000 | each socket read; a slow trickle can run far longer in total |
| `request_timeout: ms` (0.7) | `:infinity` | the whole response; HTTP/1 only, best effort |
| `finch: [pool_timeout: ms]` | 5_000 | waiting for a free pool connection (top-level `pool_timeout:` is deprecated in 0.7) |

- The worst case is `(max_retries + 1)` attempts × these timeouts, plus the backoff sleeps. With the defaults, a single `Req.get` can take over a minute.
- On user-facing paths, set tight values and few retries. In LiveView, run the call in `start_async/3` or `assign_async/3` (see the `phoenix-liveview-essentials` skill).
- Each distinct `connect_options` value starts its own Finch pool, and Req never stops it. Keep the value constant per client, never computed per request.

## JSON bodies

- **Encoding:** `json: data` calls `Jason.encode_to_iodata!/1` and sets `content-type` and `accept` to `application/json`. Req 0.7 depends on **Jason, not Elixir's `JSON` module**: `@derive JSON.Encoder` doesn't help, and a struct needs `Jason.Encoder` or raises `Protocol.UndefinedError`. Build plain maps.
- **Decoding:** the default `decoders: [:json, :json_api]` picks the decoder from the response `content-type` and uses `Jason.decode/1`, which gives string keys. Any other type (`text/html`, `text/plain`) stays a binary. Match on status first, and never assume an error body is a map.
- **Bad JSON fails the whole call:** a JSON `content-type` with an invalid body returns `{:error, %Jason.DecodeError{}}`, even for a 200.
- **`decode_body: false`** (or `decoders: false`, or `raw: true`) keeps the body as a binary. Use it when verifying a signature over the raw bytes or decoding yourself. `decoders: [json: &Jason.decode(&1, keys: :atoms)]` replaces the deprecated `decode_json:` option.
- Since 0.6, zip/tar/gz/csv bodies are no longer decoded automatically (decompression bombs). Opt in per format with `decoders: [:json, :zip]`, and only for trusted hosts. Compression is opt-in too: `compressed: true`.

## Security

- **SSRF:** a URL from a user, a webhook config or job args can point at `169.254.169.254` or internal services. Check scheme and host against an allowlist, then request with `redirect: false`; a redirect is a new, unchecked URL. The full pattern, including DNS-rebinding notes, is in the `security-essentials` skill.
- **Redirects and credentials:** when a redirect changes host, scheme or port, Req removes the `authorization` header and the `:auth` option (unless `redirect_trusted: true`). **Custom headers such as `x-api-key` are forwarded.** For APIs authenticated that way, use `redirect: false` or check the `location` yourself.
- **Logging:** `inspect(%Req.Request{})` masks `authorization` and `:auth`, but not other headers, and nothing masks bodies. Log the API name, the status and `Exception.message/1`, never `resp.body` or `req.headers`:

```elixir
require Logger

Logger.warning("weather API call failed: #{Exception.message(exception)}",
  api: :weather,
  reason: inspect(exception.__struct__)
)
```

- **TLS:** never use `connect_options: [transport_opts: [verify: :verify_none]]` outside local experiments. For a private CA, use `transport_opts: [cacertfile: path]`.
- Logger metadata conventions and filtering are in the `telemetry-essentials` skill.

## Finch pools

By default Req uses its own Finch instance: an HTTP/1 pool of up to 50 connections per `{scheme, host, port}`, never terminated. Start a named pool when you need:

- more than 50 concurrent connections to one host, or a smaller cap to protect a fragile partner;
- HTTP/2 multiplexing (`protocols: [:http2]`);
- per-host settings (connect timeout, proxy, certificates), idle-pool cleanup (`pool_max_idle_time`), or pool metrics (`start_pool_metrics?: true`).

```elixir
# lib/my_app/application.ex, in children
{Finch,
 name: MyApp.Finch,
 pools: %{
   :default => [size: 50, conn_opts: [transport_opts: [timeout: 5_000]]],
   "https://api.payments.example" => [size: 10, count: 2]
 }}

# In the client
Req.new(base_url: base_url, finch: [name: MyApp.Finch, pool_timeout: 2_000])
```

- `finch: [name: ...]` with `connect_options:` raises "cannot set both :finch and :connect_options". Put connect settings in the pool's `conn_opts`.
- `finch: [name: MyApp.Finch, size: 5]` raises too: pool options belong where the pool is started.
- The 0.5 form `finch: MyApp.Finch` still works but prints a deprecation warning.
- With `plug:` in test config, Req uses the `Req.Plug` adapter and ignores Finch options, so tests don't need the pool.

## Testing

The `testing-essentials` skill covers `Req.Test.stub/2`, `expect/3`, `json/2`, `transport_error/2` and `verify_on_exit!`. What matters most for a client:

```elixir
defmodule MyApp.PaymentsTest do
  use ExUnit.Case, async: true

  setup {Req.Test, :verify_on_exit!}

  test "posts the charge and keeps the idempotency key across retries" do
    test_pid = self()

    Req.Test.expect(MyApp.Payments, fn conn ->
      send(test_pid, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})
      Plug.Conn.send_resp(conn, 503, "")
    end)

    Req.Test.expect(MyApp.Payments, fn conn ->
      send(test_pid, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})
      assert conn.method == "POST"
      assert conn.body_params == %{"amount" => 1999, "currency" => "eur", "reference" => 42}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "ch_1"})
    end)

    # Config has retry: false; re-enable it for this call, without the sleeps
    assert {:ok, "ch_1"} =
             MyApp.Payments.create_charge(%MyApp.Orders.Order{id: 42, total_cents: 1999},
               retry: :transient,
               retry_delay: 0,
               retry_log_level: false
             )

    assert_receive {:key, ["order-42-charge"]}
    assert_receive {:key, ["order-42-charge"]}
  end
end
```

- **Assert on the outgoing request:** `conn.method`, `conn.request_path`, `conn.query_params`, `Plug.Conn.get_req_header/2`, and `conn.body_params`. The `Req.Plug` adapter runs `Plug.Parsers` for JSON, form and multipart bodies. Use `Req.Test.raw_body(conn)` for the exact bytes.
- **Simulate real failures:**
  - an error status with a JSON body: `conn |> Plug.Conn.put_status(422) |> Req.Test.json(...)`;
  - rate limiting: `Plug.Conn.put_resp_header(conn, "retry-after", "30")` before `send_resp(conn, 429, "")`;
  - a proxy error page: `Req.Test.html(conn, "<h1>Bad gateway</h1>")`;
  - broken JSON: `put_resp_content_type("application/json")` with an invalid body;
  - network errors: `Req.Test.transport_error(conn, :timeout)`.
- **Other processes:** since 0.7, processes started by the test (`Task`, `start_supervised!`, `GenServer.start`) find the test's stubs automatically. Processes started by the application need `Req.Test.allow(MyApp.Weather, self(), pid)`. If you can't get the pid, use `setup {Req.Test, :set_req_test_to_shared}` with `async: false`.
- **Mox** is for callers that shouldn't know about HTTP, such as a LiveView that shows the temperature. Put a behaviour in front of the client and test the client itself with `Req.Test`. Wiring is in the [reference](reference.md#behaviour-and-mox).

## Observability

- **Finch telemetry:** `[:finch, :request, :start | :stop | :exception]`, `[:finch, :queue, ...]` (pool checkout), `[:finch, :connect, ...]`, `[:finch, :send, ...]`, `[:finch, :recv, ...]`, `[:finch, :reused_connection]`. Metadata has `:name` (the Finch instance) and `:request` (a `%Finch.Request{}` with host, path and method). These events fire once **per attempt**. Add `finch_private: %{api: :weather}` to the client and it shows up as `meta.request.private.api`.
- **One event per logical call** (after retries, tagged with your API name): use a small Req plugin that adds a request step and a response/error step. It's in the [reference](reference.md#telemetry-plugin).
- **Tracing:** `Req.new(...) |> OpentelemetryReq.attach()` (`opentelemetry_req` 1.0 attaches cleanly on Req 0.7). Exporter setup is in the `telemetry-essentials` skill.
- Use metric tags with few values (`api`, `status`), never the URL with ids in it.

## Resilience

- **Circuit breaking:** when an upstream is down, fail fast instead of tying up every caller for the full timeout. A Req plugin built on `:fuse` checks the fuse in a request step (`Req.Request.halt/2` when blown) and melts it on 5xx and transport errors. Code is in the [reference](reference.md#circuit-breaker-with-fuse).
- **Rate limits:** treat 429 as a result (`{:error, :rate_limited}`). In Oban, snooze for the `Retry-After` value. To limit your own call rate, the simplest control is the concurrency of a dedicated Oban queue. Global and distributed rate limits are Oban Pro, or a token bucket you write and own.
- **Caching:** cache the decoded domain value (`{:ok, celsius}`), not the `%Req.Response{}`, in ETS or Cachex with a TTL and a key built from the request inputs. Req's own `cache: true` step is deprecated since 0.7.1.

## Upgrading from Req 0.5

| 0.5 | 0.7 |
|---|---|
| `finch: MyFinch` | `finch: [name: MyFinch]` |
| `pool_timeout: ms` | `finch: [pool_timeout: ms]` |
| `decode_json: [keys: :atoms]` | `decoders: [json: &Jason.decode(&1, keys: :atoms)]` |
| `retry_delay:` and `Retry-After` both apply | setting `retry_delay` ignores `Retry-After` |
| zip/tar/gz/csv decoded automatically | only JSON; opt in with `decoders:` (0.6) |
| compressed responses requested by default | `compressed: true` to opt in (0.6.1) |
| `run_finch` / `put_plug` steps | `Req.Finch` / `Req.Plug` adapter modules |
| `cache: true` | deprecated (0.7.1) |
| retry delays without jitter | jitter by default |
