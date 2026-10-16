# HTTP Clients with Req: Reference

Supporting material for the `http-clients-req` skill. Every module here was compiled and tested against Req 0.7.5, Finch 0.24, fuse 2.5 and Mox 1.3.

## Telemetry plugin

Finch's events fire once per attempt and don't know which API they belong to. This plugin emits one event per logical call, after retries, tagged with your API name.

```elixir
defmodule MyApp.HTTPTelemetry do
  @moduledoc """
  Emits `[:my_app, :http, :request, :stop]` once per logical request (after retries).
  Measurements: `%{duration: native_time}`; metadata: `%{api:, method:, status:, error:}`.
  """

  def attach(%Req.Request{} = req, opts) do
    req
    |> Req.Request.register_options([:api])
    |> Req.Request.merge_options(opts)
    |> Req.Request.prepend_request_steps(telemetry_start: &start/1)
    |> Req.Request.append_response_steps(telemetry_stop: &stop/1)
    |> Req.Request.append_error_steps(telemetry_stop: &stop/1)
  end

  # Retries re-run request steps; keep the first attempt's start time
  defp start(req) do
    Req.Request.update_private(req, :telemetry_start, System.monotonic_time(), & &1)
  end

  defp stop({req, response_or_exception}) do
    duration = System.monotonic_time() - Req.Request.get_private(req, :telemetry_start)

    metadata =
      case response_or_exception do
        %Req.Response{status: status} -> %{status: status, error: nil}
        exception -> %{status: nil, error: exception.__struct__}
      end

    :telemetry.execute(
      [:my_app, :http, :request, :stop],
      %{duration: duration},
      Map.merge(metadata, %{api: req.options[:api], method: req.method})
    )

    {req, response_or_exception}
  end
end

# In the client's new/0:
#   Req.new(...) |> MyApp.HTTPTelemetry.attach(api: :payments)
```

How it works:

- `register_options/2` is required. Without it, `api:` fails Req's option validation with `ArgumentError`.
- The `retry` response step runs first. When it retries, it runs the whole pipeline again, request steps included, and halts the outer one. So the steps appended here run once, on the final result. The request step runs on every attempt, which is why it keeps the first timestamp.
- A request step that halts (like the circuit breaker below) skips the response and error steps, so a call rejected by an open circuit emits no event.
- Report it with `Telemetry.Metrics.summary("my_app.http.request.stop.duration", unit: {:native, :millisecond}, tags: [:api, :status])`. The `telemetry-essentials` skill covers wiring metrics.

## Circuit breaker with `:fuse`

`{:fuse, "~> 2.5"}` (an Erlang library) tolerates `MaxR` failures in `MaxT` ms, then "blows" for the reset period. While it's blown, calls fail at once instead of waiting for timeouts.

```elixir
defmodule MyApp.CircuitBreaker do
  @moduledoc "Req plugin backed by :fuse — fail fast while an upstream is down."

  # Blow after 5 failures within 10 s; try again after 30 s
  def install(name), do: :fuse.install(name, {{:standard, 5, 10_000}, {:reset, 30_000}})

  def attach(%Req.Request{} = req, opts) do
    req
    |> Req.Request.register_options([:fuse])
    |> Req.Request.merge_options(opts)
    |> Req.Request.prepend_request_steps(fuse_check: &check/1)
    |> Req.Request.append_response_steps(fuse_melt: &melt_on_5xx/1)
    |> Req.Request.append_error_steps(fuse_melt: &melt_on_error/1)
  end

  defp check(req) do
    case :fuse.ask(req.options[:fuse], :sync) do
      :ok -> req
      :blown -> Req.Request.halt(req, RuntimeError.exception("circuit open: #{req.options[:fuse]}"))
      {:error, :not_found} -> req
    end
  end

  defp melt_on_5xx({req, %Req.Response{status: status} = response}) do
    if status >= 500, do: :fuse.melt(req.options[:fuse])
    {req, response}
  end

  defp melt_on_error({req, exception}) do
    :fuse.melt(req.options[:fuse])
    {req, exception}
  end
end
```

```elixir
# lib/my_app/application.ex, before the children start
:ok = MyApp.CircuitBreaker.install(:payments)

# In the client's new/0
Req.new(...) |> MyApp.CircuitBreaker.attach(fuse: :payments)
```

- A blown circuit returns `{:error, %RuntimeError{message: "circuit open: payments"}}` from `Req.request/2`, which lands in the client's `{:error, exception}` clause. Define your own exception module if callers need to match on it.
- Melting happens once per logical call, after Req's retries, so a call that needed three retries counts as one failure.
- 4xx responses don't melt the fuse: they are the caller's problem, not the upstream's.
- Fuses are global (one per name, per node). Tests that make failing calls through a shared fuse should reset it in `setup` (`:fuse.reset(:payments)`) and run with `async: false`, or install a separate fuse just for the test.

## Behaviour and Mox

Use this when callers (LiveViews, contexts, workers) should depend on "a weather source", not on HTTP. Then their tests stub domain results instead of HTTP responses.

```elixir
defmodule MyApp.WeatherClient do
  @moduledoc "Boundary for weather lookups; the HTTP implementation is MyApp.Weather."

  @callback current(city :: String.t(), opts :: keyword()) :: {:ok, float()} | {:error, term()}

  def current(city, opts \\ []), do: impl().current(city, opts)

  defp impl, do: Application.get_env(:my_app, :weather_client, MyApp.Weather)
end

# MyApp.Weather adds `@behaviour MyApp.WeatherClient` and `@impl true` on current/2.
```

```elixir
# test/test_helper.exs
Mox.defmock(MyApp.WeatherMock, for: MyApp.WeatherClient)

# config/test.exs
config :my_app, :weather_client, MyApp.WeatherMock
```

```elixir
defmodule MyApp.WeatherClientTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  test "callers use the behaviour; tests swap in the mock" do
    expect(MyApp.WeatherMock, :current, fn "Lisbon", [] -> {:ok, 21.5} end)
    assert {:ok, 21.5} = MyApp.WeatherClient.current("Lisbon")
  end
end
```

- Callers go through `MyApp.WeatherClient.current/2`. Test `MyApp.Weather` itself by calling it directly with `Req.Test` stubs, so the HTTP mapping is still covered.
- Read the implementation with `Application.get_env/3` at call time, not `compile_env`, so tests can swap it.
- Mox expectations follow the same ownership rules as `Req.Test` (`$callers`, `Mox.allow/3`). See the `testing-essentials` skill.
- If the only consumer is the context that wraps the client, skip the behaviour: `Req.Test` alone is less code and tests more.
