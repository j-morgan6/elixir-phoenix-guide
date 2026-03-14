---
name: oban-essentials
description: MANDATORY for ALL Oban work. Invoke before writing workers or enqueuing jobs.
file_patterns:
  - "**/workers/**/*.ex"
  - "**/*_worker.ex"
auto_suggest: true
---

# Oban Essentials

## RULES — Follow these with no exceptions

1. **Always `use Oban.Worker`** with explicit `queue` and `max_attempts` options
2. **Return `{:ok, result}` for success, `{:error, reason}` for retryable failures, `{:cancel, reason}` for permanent failures** — never return bare `:ok` or raise
3. **Make workers idempotent** — the same job may run more than once due to retries or node restarts
4. **Use `unique` option to prevent duplicate jobs** — specify `period`, `fields`, and `keys`
5. **Test with `Oban.Testing`** — use `assert_enqueued` and `perform_job`, never call `perform/1` directly
6. **Never put large data in job args** — store IDs and fetch fresh data in the worker
7. **Use `Oban.insert/1`** (not `Oban.insert!/1`) and handle the error tuple

---

## Worker Definition

```elixir
defmodule MyApp.Workers.SendWelcomeEmail do
  use Oban.Worker,
    queue: :mailers,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:user_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case MyApp.Accounts.get_user(user_id) do
      nil ->
        {:cancel, "user #{user_id} not found"}

      user ->
        MyApp.Mailer.send_welcome(user)
        {:ok, :sent}
    end
  end
end
```

### Key Points

- `queue` — which queue runs this worker (must match config)
- `max_attempts` — total attempts including the first (3 = 1 original + 2 retries)
- `unique` — deduplication; `period` in seconds, `keys` specifies which args fields to compare
- Pattern match on `%Oban.Job{args: ...}` — args are always string-keyed maps (JSON serialized)

---

## Enqueuing Jobs

```elixir
# Basic insert — always handle the result
case MyApp.Workers.SendWelcomeEmail.new(%{user_id: user.id}) |> Oban.insert() do
  {:ok, job} -> {:ok, job}
  {:error, changeset} -> {:error, changeset}
end

# Schedule for later
%{user_id: user.id}
|> MyApp.Workers.SendWelcomeEmail.new(schedule_in: 3600)
|> Oban.insert()

# Bad — raises on failure, no error handling
MyApp.Workers.SendWelcomeEmail.new(%{user_id: user.id}) |> Oban.insert!()
```

### Enqueuing from Contexts

Enqueue jobs from context modules, not LiveViews or controllers:

```elixir
# Good — context handles the job
defmodule MyApp.Accounts do
  def register_user(attrs) do
    with {:ok, user} <- create_user(attrs) do
      MyApp.Workers.SendWelcomeEmail.new(%{user_id: user.id})
      |> Oban.insert()

      {:ok, user}
    end
  end
end

# Bad — LiveView enqueues directly
def handle_event("register", params, socket) do
  MyApp.Workers.SendWelcomeEmail.new(%{user_id: user.id}) |> Oban.insert()
end
```

---

## Return Values

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: args}) do
  # Success — job completed, marked as completed
  {:ok, result}

  # Retryable failure — will retry up to max_attempts
  {:error, reason}

  # Permanent failure — will NOT retry, marked as cancelled
  {:cancel, reason}

  # Snooze — reschedule for later (in seconds)
  {:snooze, 60}
end
```

**Never raise in workers.** An unhandled exception counts as a retryable failure but produces noisy logs and stack traces. Use explicit `{:error, reason}` instead.

---

## Queue Configuration

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,      # 10 concurrent jobs
    mailers: 5,       # 5 concurrent email jobs
    imports: 2         # 2 concurrent import jobs (resource-heavy)
  ]

# config/test.exs — use testing mode
config :my_app, Oban,
  testing: :inline    # Jobs execute immediately in the test process
```

---

## Idempotency

Workers must be safe to run multiple times with the same args.

```elixir
# Bad — sends duplicate emails on retry
@impl Oban.Worker
def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
  user = MyApp.Accounts.get_user!(user_id)
  MyApp.Mailer.send_welcome(user)
  {:ok, :sent}
end

# Good — check if already processed
@impl Oban.Worker
def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
  user = MyApp.Accounts.get_user!(user_id)

  if user.welcome_email_sent_at do
    {:ok, :already_sent}
  else
    with {:ok, _} <- MyApp.Mailer.send_welcome(user),
         {:ok, _} <- MyApp.Accounts.mark_welcome_sent(user) do
      {:ok, :sent}
    end
  end
end
```

---

## Unique Jobs

Prevent duplicate jobs from being enqueued:

```elixir
use Oban.Worker,
  queue: :default,
  unique: [
    period: 300,              # 5-minute uniqueness window
    fields: [:args, :queue],  # match on these fields
    keys: [:user_id],         # only compare these arg keys
    states: [:available, :scheduled, :executing]  # check these states
  ]
```

### When to Use

- **Email sending** — don't send the same email twice within 5 minutes
- **Data syncing** — don't start a sync if one is already running
- **Webhook delivery** — deduplicate retry attempts

---

## Scheduled and Recurring Jobs

```elixir
# Schedule a job for later
%{report_id: report.id}
|> MyApp.Workers.GenerateReport.new(schedule_in: {1, :hour})
|> Oban.insert()

# Cron-based recurring jobs (in config)
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"0 2 * * *", MyApp.Workers.NightlyCleanup},
      {"*/15 * * * *", MyApp.Workers.SyncData, args: %{source: "api"}}
    ]}
  ]
```

---

## Pruning

Keep the jobs table from growing indefinitely:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}  # 7 days
  ]
```

---

## Testing

```elixir
# test/my_app/workers/send_welcome_email_test.exs
defmodule MyApp.Workers.SendWelcomeEmailTest do
  use MyApp.DataCase, async: true
  use Oban.Testing, repo: MyApp.Repo

  alias MyApp.Workers.SendWelcomeEmail

  test "enqueuing a welcome email job" do
    user = user_fixture()

    SendWelcomeEmail.new(%{user_id: user.id})
    |> Oban.insert()

    assert_enqueued(worker: SendWelcomeEmail, args: %{user_id: user.id})
  end

  test "performing the job sends the email" do
    user = user_fixture()

    assert {:ok, :sent} =
      perform_job(SendWelcomeEmail, %{user_id: user.id})
  end

  test "cancels if user not found" do
    assert {:cancel, _reason} =
      perform_job(SendWelcomeEmail, %{user_id: -1})
  end
end
```

### Testing Rules

- **Use `perform_job/2`** — not `perform/1`. `perform_job` validates args and simulates the Oban runtime.
- **Use `assert_enqueued/1`** — verify jobs were enqueued with correct args.
- **Use `Oban.Testing` inline mode** in test config — jobs run synchronously in the test process.
- **Test all return paths** — success, retryable error, and cancel.

---

## Job Args Best Practices

```elixir
# Bad — large data in args (stored as JSON in database)
SendReport.new(%{
  user_id: user.id,
  report_data: large_data_structure  # Don't do this!
})

# Good — store IDs, fetch fresh data in worker
SendReport.new(%{user_id: user.id, report_id: report.id})

# Bad — non-JSON-serializable args
SendEmail.new(%{user: user})  # Structs don't serialize to JSON

# Good — pass IDs, fetch in worker
SendEmail.new(%{user_id: user.id})
```

---

## Error Handling

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: %{"url" => url}, attempt: attempt}) do
  case HTTPClient.get(url) do
    {:ok, %{status: 200, body: body}} ->
      {:ok, process(body)}

    {:ok, %{status: 404}} ->
      {:cancel, "resource not found at #{url}"}

    {:ok, %{status: 429}} ->
      {:snooze, retry_delay(attempt)}

    {:error, reason} ->
      {:error, reason}  # Will retry up to max_attempts
  end
end

defp retry_delay(attempt), do: attempt * 60  # Exponential-ish backoff
```

See `testing-essentials` skill for comprehensive testing patterns.
