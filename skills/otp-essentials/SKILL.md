---
name: otp-essentials
description: "Use when writing GenServer, Supervisor, Task, Agent, Registry or ETS code — call vs cast, supervision and restart strategies, process naming, timeouts, async work. Not for LiveView async (use phoenix-liveview-essentials)."
---

# OTP Essentials

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 — October 2026

## RULES — Follow these with no exceptions

1. **Always use `@impl true`** before GenServer/Supervisor/Agent callbacks
2. **Keep `init/1` fast** — return `{:ok, state, {:continue, term}}` and do DB/network setup in `handle_continue/2`; a slow `init` blocks the supervisor and app boot
3. **Default to `GenServer.call`** — it gives back-pressure and a 5 s timeout. Use `cast` only for cheap state updates you can afford to lose; send slow side effects (email, HTTP) to `Task.Supervisor` or Oban
4. **Wrap every process behind a public API module** — callers never write `GenServer.call(pid, ...)` themselves
5. **One argument shape: `start_link(opts)` with a keyword list** — read it with `Keyword.fetch!/2`; child specs pass `{MyApp.Room, room_id: id}`
6. **Registry for dynamic processes; atoms only for singletons** — never build a name with `String.to_atom/1`
7. **Every long-running process is supervised** — no bare `spawn`/`Task.start`; inside a LiveView use `start_async/3` or `assign_async/3`
8. **Every `Task.async` is awaited** — for collections use `Task.Supervisor.async_stream_nolink/4` with `on_timeout: :kill_task`
9. **Don't rely on `terminate/2` for cleanup** — on supervisor shutdown it runs only if the process traps exits; use links or monitors for cleanup that must happen

---

## GenServer

### Public API

```elixir
defmodule MyApp.Cache do
  use GenServer

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def get(server \\ __MODULE__, key), do: GenServer.call(server, {:get, key})

  def put(server \\ __MODULE__, key, value), do: GenServer.call(server, {:put, key, value})

  # --- Callbacks ---

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}

  def handle_call({:put, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}
end
```

### Fast init with handle_continue

<!-- epg:bad -->
```elixir
@impl true
def init(_opts) do
  items = MyApp.Repo.all(MyApp.Item)  # blocks the supervisor until the query returns
  {:ok, %{items: items}}
end
```

```elixir
@impl true
def init(_opts), do: {:ok, %{items: []}, {:continue, :load}}

@impl true
def handle_continue(:load, state), do: {:noreply, %{state | items: MyApp.Repo.all(MyApp.Item)}}
```

### call vs cast

- `GenServer.call/3` waits 5 000 ms by default, then **exits the caller** (the server keeps working and its late reply is discarded). Pass a timeout only when you know the work is slower: `GenServer.call(server, msg, to_timeout(second: 30))`.
- `cast` returns immediately, gives no back-pressure (a flooded mailbox grows without bound), and the message is lost if the server crashes. Fine for `increment`; wrong for "send this email".

<!-- epg:bad -->
```elixir
# Fire-and-forget through a GenServer: the email is lost if EmailServer crashes
def send_welcome(user), do: GenServer.cast(EmailServer, {:send, user})
```

```elixir
# Work that may be lost: a supervised task. Work that must happen: an Oban job.
def send_welcome(user) do
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> MyApp.Mailer.deliver_welcome(user) end)
end
```

### Deferred replies with GenServer.reply/2

Return `{:noreply, state}` from `handle_call/3`, keep `from`, and reply later. The server stays responsive while slow work runs elsewhere:

```elixir
@impl true
def handle_call({:lookup, key}, from, state) do
  task = Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn -> slow_lookup(key) end)
  {:noreply, put_in(state.waiting[task.ref], from)}
end

@impl true
def handle_info({ref, result}, state) when is_reference(ref) do
  Process.demonitor(ref, [:flush])
  {from, waiting} = Map.pop!(state.waiting, ref)
  GenServer.reply(from, {:ok, result})
  {:noreply, %{state | waiting: waiting}}
end

def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
  {from, waiting} = Map.pop!(state.waiting, ref)
  GenServer.reply(from, {:error, reason})
  {:noreply, %{state | waiting: waiting}}
end
```

### handle_info and unexpected messages

Timers, monitors, PubSub and task replies arrive in `handle_info/2`. Once you define `handle_info/2`, an unmatched message raises `FunctionClauseError`; add a final clause if stray messages are possible.

```elixir
require Logger

@impl true
def handle_info(:tick, state) do
  Process.send_after(self(), :tick, 1_000)
  {:noreply, %{state | count: state.count + 1}}
end

def handle_info(msg, state) do
  Logger.warning("unexpected message: #{inspect(msg)}", server: __MODULE__)
  {:noreply, state}
end
```

### Expected vs unexpected errors

Reply with `{:error, reason}` for failures the caller can act on; let everything else crash so the supervisor restarts with clean state.

```elixir
require Logger

@impl true
def handle_call({:charge, order_id}, _from, state) do
  case Payments.charge(order_id) do
    {:ok, receipt} ->
      {:reply, {:ok, receipt}, state}

    {:error, reason} ->
      Logger.error("charge failed: #{inspect(reason)}", order_id: order_id)
      {:reply, {:error, reason}, state}
  end
end
```

### terminate/2

`terminate/2` runs when a callback returns `{:stop, ...}` or raises. On supervisor shutdown it runs **only if the process traps exits** (`Process.flag(:trap_exit, true)` in `init/1`) and its child spec `shutdown` isn't `:brutal_kill`. It never runs on `Process.exit(pid, :kill)` or a VM crash. Put cleanup that must happen in another process that monitors this one.

---

## Supervisors

### Strategies and restart values

- `:one_for_one` (default choice): restart only the failed child.
- `:rest_for_one`: restart the failed child and every child started after it (later children depend on earlier ones).
- `:one_for_all`: restart all children (they share state).
- A supervisor gives up after 3 restarts in 5 s (`max_restarts`/`max_seconds`) and exits, escalating to its parent.

Child `restart:` values: `:permanent` (default for GenServer, always restarted), `:transient` (restarted only after an abnormal exit; use for processes that finish their job and stop with `:normal`), `:temporary` (never restarted; default for `Task.Supervisor.start_child/3`).

```elixir
defmodule MyApp.Import do
  use GenServer, restart: :transient
  # stops with {:stop, :normal, state} when done; restarted only if it crashes
end
```

### Application supervision tree

Start order follows the generated Phoenix 1.8 `application.ex`; your processes go before the Endpoint:

```elixir
children = [
  MyAppWeb.Telemetry,
  MyApp.Repo,
  {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Registry, keys: :unique, name: MyApp.Registry},
  {Task.Supervisor, name: MyApp.TaskSupervisor},
  {DynamicSupervisor, name: MyApp.RoomSupervisor, strategy: :one_for_one},
  MyApp.Cache,
  MyAppWeb.Endpoint
]
```

### Dynamic children with Registry names

```elixir
defmodule MyApp.Room do
  use GenServer, restart: :transient

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def start(room_id) do
    DynamicSupervisor.start_child(MyApp.RoomSupervisor, {__MODULE__, room_id: room_id})
  end

  def whereis(room_id) do
    case Registry.lookup(MyApp.Registry, {:room, room_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp via(room_id), do: {:via, Registry, {MyApp.Registry, {:room, room_id}}}

  @impl true
  def init(room_id), do: {:ok, %{room_id: room_id, members: MapSet.new()}}
end
```

`DynamicSupervisor.start_child/2` returns `{:error, {:already_started, pid}}` when the name is taken; treat that as success if you only need the pid.

### PartitionSupervisor for a bottleneck supervisor

One `DynamicSupervisor` (or one GenServer) serialises every `start_child`. `PartitionSupervisor` (1.14+) runs one copy per scheduler and routes by key:

```elixir
# application.ex
{PartitionSupervisor, child_spec: DynamicSupervisor, name: MyApp.RoomSupervisors}

# starting a room
DynamicSupervisor.start_child(
  {:via, PartitionSupervisor, {MyApp.RoomSupervisors, room_id}},
  {MyApp.Room, room_id: room_id}
)
```

---

## Tasks

```elixir
# Concurrent work you wait for, with an explicit timeout
profile = Task.async(fn -> fetch_profile(user_id) end)
posts = Task.async(fn -> fetch_posts(user_id) end)
{Task.await(profile, 5_000), Task.await(posts, 5_000)}

# A collection: bounded concurrency, slow items killed, crashes don't take the caller down
MyApp.TaskSupervisor
|> Task.Supervisor.async_stream_nolink(urls, &fetch/1,
  max_concurrency: 8,
  timeout: 10_000,
  on_timeout: :kill_task
)
|> Enum.flat_map(fn
  {:ok, result} -> [result]
  {:exit, _reason} -> []
end)
```

- `Task.async/1` links the task to the caller: if the task crashes, so does the caller. Use `Task.Supervisor.async_nolink/2` when the caller must survive.
- Plain `Task.async_stream/3` defaults to `on_timeout: :exit`, which crashes the caller on the first slow item.
- In a LiveView, use `start_async/3` + `handle_async/3` (or `assign_async/3`), never `Task.async`: LiveView supervises the task, cancels it when the user leaves, and turns crashes into `{:exit, reason}`. See the `phoenix-liveview-essentials` skill.

---

## Agent

Use an Agent only for trivial get/update state. Anything needing `handle_info`, timeouts or multi-step logic is a GenServer.

```elixir
defmodule MyApp.Counter do
  use Agent

  def start_link(opts) do
    Agent.start_link(fn -> 0 end, name: Keyword.get(opts, :name, __MODULE__))
  end

  def value(counter \\ __MODULE__), do: Agent.get(counter, & &1)

  def increment(counter \\ __MODULE__), do: Agent.update(counter, &(&1 + 1))
end
```

---

## Process naming

- Singletons: `name: __MODULE__`.
- One process per entity (room, user, game): a `{:via, Registry, {MyApp.Registry, key}}` name, as in `MyApp.Room` above.
- Never `String.to_atom("room_#{id}")`: atoms are never garbage collected and the atom table has a fixed limit.

## Links vs monitors

`Process.link/1` is bidirectional (crashes propagate; that's what supervisors use). `Process.monitor/1` is one-way: the watcher gets `{:DOWN, ref, :process, pid, reason}` in `handle_info/2` and keeps running. Use monitors to observe processes you don't own.

## ETS for read-heavy shared state

The owner process creates the table and is the only writer; every other process reads directly. The default access is `:protected` (owner writes, all read), so don't pass `:public` unless other processes must write.

```elixir
@impl true
def init(_opts) do
  :ets.new(:my_cache, [:named_table, :set, read_concurrency: true])
  {:ok, %{}}
end

# Readers (any process): no GenServer round trip
def lookup(key) do
  case :ets.lookup(:my_cache, key) do
    [{^key, value}] -> {:ok, value}
    [] -> :error
  end
end

# Writers go through the owner
def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

@impl true
def handle_call({:put, key, value}, _from, state) do
  :ets.insert(:my_cache, {key, value})
  {:reply, :ok, state}
end
```

The table dies with its owner. If the cache must survive restarts of the writer, make the owner a separate, minimal process.

---

## Anti-patterns

- **Bottleneck GenServer:** every read goes through one process. Use ETS, the database, or `PartitionSupervisor`.
- **God process:** one GenServer owning unrelated state. Split by responsibility.
- **Process as a code-organisation tool:** if there's no state, concurrency or failure isolation to manage, write a plain module.
- **Unawaited `Task.async`:** the reply message leaks into the caller's mailbox. Await it, or use `Task.Supervisor.start_child/2`.

---

## Testing

Start processes with `start_supervised!/1` (stopped after each test) and observe exits with a monitor, never with `Process.sleep`:

```elixir
test "a room stops when the last member leaves" do
  pid = start_supervised!({MyApp.Room, room_id: "lobby"})
  ref = Process.monitor(pid)

  :ok = MyApp.Room.join(pid, "alice")
  :ok = MyApp.Room.leave(pid, "alice")

  assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
end
```

Name test processes uniquely (or not at all) so `async: true` tests don't collide: `start_supervised!({MyApp.Cache, name: :"cache_#{System.unique_integer()}"})` is fine in tests because the atom count is bounded by the test count. See the `testing-essentials` skill.
