---
name: otp-essentials
description: MANDATORY for ALL OTP work. Invoke before writing GenServer, Supervisor, Task, or Agent modules.
file_patterns:
  - "**/*.ex"
auto_suggest: true
---

# OTP Essentials

## RULES — Follow these with no exceptions

1. **Always use `@impl true`** before GenServer/Agent callbacks (init, handle_call, handle_cast, handle_info, terminate)
2. **Keep `init/1` fast** — no blocking calls, no DB queries; use `handle_continue` for expensive setup
3. **Use `GenServer.call` for request/response, `GenServer.cast` for fire-and-forget** — never cast when you need a result
4. **Always define a public API wrapping GenServer calls** — callers should never use `GenServer.call(pid, ...)` directly
5. **Use `Task.async`/`Task.await` with bounded timeouts** — never `Task.async` without a corresponding `Task.await` or `Task.yield`
6. **Name processes via Registry, not atoms** — atom table is finite and never garbage collected
7. **Supervisors own process lifecycle** — never start unsupervised long-running processes

---

## GenServer

### Public API Pattern

Always wrap GenServer calls behind a public module API. Callers should not know they're talking to a GenServer.

```elixir
# Bad — leaks GenServer implementation to callers
GenServer.call(MyApp.Cache, {:get, key})

# Good — public API hides the GenServer
defmodule MyApp.Cache do
  use GenServer

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get(key, server \\ __MODULE__) do
    GenServer.call(server, {:get, key})
  end

  def put(key, value, server \\ __MODULE__) do
    GenServer.cast(server, {:put, key, value})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  @impl true
  def handle_cast({:put, key, value}, state) do
    {:noreply, Map.put(state, key, value)}
  end
end
```

### Fast Init with handle_continue

Never block in `init/1`. Use `handle_continue` for expensive setup.

```elixir
# Bad — blocks the supervisor while loading data
@impl true
def init(opts) do
  data = MyApp.Repo.all(MyApp.Item)  # Blocks!
  {:ok, %{items: data}}
end

# Good — returns immediately, loads data asynchronously
@impl true
def init(opts) do
  {:ok, %{items: []}, {:continue, :load_data}}
end

@impl true
def handle_continue(:load_data, state) do
  data = MyApp.Repo.all(MyApp.Item)
  {:noreply, %{state | items: data}}
end
```

### call vs cast

```elixir
# call — synchronous, caller waits for reply (use for reads, queries)
def get_count(server \\ __MODULE__) do
  GenServer.call(server, :get_count)
end

@impl true
def handle_call(:get_count, _from, state) do
  {:reply, state.count, state}
end

# cast — asynchronous, fire-and-forget (use for writes, side effects)
def increment(server \\ __MODULE__) do
  GenServer.cast(server, :increment)
end

@impl true
def handle_cast(:increment, state) do
  {:noreply, %{state | count: state.count + 1}}
end
```

### handle_info for External Messages

Use `handle_info` for messages not sent via `call`/`cast` — timers, monitors, PubSub, etc.

```elixir
@impl true
def init(_opts) do
  Process.send_after(self(), :tick, 1_000)
  {:ok, %{count: 0}}
end

@impl true
def handle_info(:tick, state) do
  Process.send_after(self(), :tick, 1_000)
  {:noreply, %{state | count: state.count + 1}}
end
```

---

## Supervisors

### Supervision Strategies

```elixir
# one_for_one — restart only the failed child (most common)
children = [
  {MyApp.Cache, []},
  {MyApp.Worker, []}
]
Supervisor.start_link(children, strategy: :one_for_one)

# one_for_all — restart ALL children when one fails
# Use when children depend on each other's state
Supervisor.start_link(children, strategy: :one_for_all)

# rest_for_one — restart failed child and all children started AFTER it
# Use when later children depend on earlier ones
Supervisor.start_link(children, strategy: :rest_for_one)
```

### Application Supervision Tree

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      MyApp.Cache,
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### DynamicSupervisor for Runtime Children

Use when you need to start processes on demand, not at boot.

```elixir
defmodule MyApp.RoomSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_room(room_id) do
    spec = {MyApp.Room, room_id: room_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_room(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
```

---

## Tasks

### async/await for Concurrent Work

```elixir
# Parallel fetch with bounded timeout
task1 = Task.async(fn -> fetch_user_profile(user_id) end)
task2 = Task.async(fn -> fetch_user_posts(user_id) end)

profile = Task.await(task1, 5_000)
posts = Task.await(task2, 5_000)
```

### async_stream for Batch Processing

```elixir
# Process items concurrently with bounded concurrency
user_ids
|> Task.async_stream(&fetch_user/1, max_concurrency: 4, timeout: 10_000)
|> Enum.map(fn {:ok, result} -> result end)
```

### Supervised Tasks (fire-and-forget)

For work that should be supervised but doesn't need a result:

```elixir
# Add to your supervision tree
{Task.Supervisor, name: MyApp.TaskSupervisor}

# Start supervised tasks (automatically restarted on crash)
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  send_welcome_email(user)
end)
```

---

## Agent

Use Agent for simple state when GenServer is overkill. If you need `handle_info`, timeouts, or complex logic, use GenServer instead.

```elixir
defmodule MyApp.Counter do
  use Agent

  def start_link(initial_value) do
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  def value do
    Agent.get(__MODULE__, & &1)
  end

  def increment do
    Agent.update(__MODULE__, &(&1 + 1))
  end
end
```

---

## Process Naming

### Registry (preferred)

```elixir
# In application supervision tree
{Registry, keys: :unique, name: MyApp.Registry}

# In GenServer start_link
def start_link(room_id) do
  GenServer.start_link(__MODULE__, room_id,
    name: {:via, Registry, {MyApp.Registry, {:room, room_id}}}
  )
end

# Lookup
def get_room(room_id) do
  case Registry.lookup(MyApp.Registry, {:room, room_id}) do
    [{pid, _}] -> {:ok, pid}
    [] -> {:error, :not_found}
  end
end
```

### Atoms (only for singletons)

```elixir
# OK — single global process
GenServer.start_link(__MODULE__, opts, name: __MODULE__)

# Bad — dynamic atom creation from user input
GenServer.start_link(__MODULE__, opts, name: String.to_atom("room_#{room_id}"))
```

---

## Process Linking vs Monitoring

```elixir
# Link — bidirectional, crash propagates (use in supervisors)
Process.link(pid)

# Monitor — unidirectional, receive :DOWN message (use for observation)
ref = Process.monitor(pid)

@impl true
def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
  # Handle monitored process dying
  {:noreply, cleanup(state, pid)}
end
```

---

## ETS for Shared Read-Heavy State

When many processes need to read the same data and writes are infrequent:

```elixir
# Create table in a GenServer (owner process)
@impl true
def init(_opts) do
  table = :ets.new(:my_cache, [:named_table, :set, :public, read_concurrency: true])
  {:ok, %{table: table}}
end

# Any process can read
:ets.lookup(:my_cache, key)

# Only owner should write (or use :public carefully)
:ets.insert(:my_cache, {key, value})
```

---

## Common Anti-Patterns

```elixir
# Bad — bottleneck GenServer (all requests go through one process)
def get_user(id), do: GenServer.call(UserServer, {:get, id})
# Fix: Use ETS, a database, or partition work across multiple processes

# Bad — god process (one GenServer doing everything)
# Fix: Split into focused processes, each with one responsibility

# Bad — unmonitored Task.async
Task.async(fn -> do_work() end)
# no await or yield — caller loses track of work
# Fix: Always await, or use Task.Supervisor.start_child for fire-and-forget

# Bad — blocking the caller unnecessarily
def send_email(user) do
  GenServer.call(EmailServer, {:send, user})  # Waits for email to send
end
# Fix: Use cast if caller doesn't need the result
def send_email(user) do
  GenServer.cast(EmailServer, {:send, user})
end
```

---

## Testing

```elixir
# Start GenServer in test
test "get and put values" do
  start_supervised!({MyApp.Cache, name: :test_cache})

  assert MyApp.Cache.get(:key, :test_cache) == nil
  MyApp.Cache.put(:key, "value", :test_cache)
  assert MyApp.Cache.get(:key, :test_cache) == "value"
end

# Test with Task
test "concurrent fetch" do
  task = Task.async(fn -> MyApp.fetch_data() end)
  assert {:ok, data} = Task.await(task, 5_000)
end
```

See `testing-essentials` skill for comprehensive testing patterns.
