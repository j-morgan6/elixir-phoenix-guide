---
name: oban-essentials
description: "Use when writing or enqueuing Oban background jobs — worker options, return values, idempotency, uniqueness, transactional enqueue, cron/pruner/lifeline config, Oban.Testing."
---

# Oban Essentials

> Verified against Elixir 1.20, Ecto 3.14, Oban 2.24, Req 0.7 — October 2026

## RULES — Follow these with no exceptions

1. **`use Oban.Worker` with explicit `queue:` and `max_attempts:`**, and match string-keyed args in `perform/1`
2. **Return `:ok`/`{:ok, value}` for success, `{:error, reason}` to retry, `{:cancel, reason}` to stop for good, `{:snooze, period}` to re-run later** — prefer tuples over raising
3. **Enqueue in the same transaction as the data the job needs** — `Oban.insert/2` inside `Repo.transact/2`, or `Oban.insert/3` in an `Ecto.Multi`; handle the result (no `Oban.insert!` in app code)
4. **Make workers idempotent** — a job can run more than once (retries, Lifeline rescues); record completion and send an idempotency key to external APIs
5. **Uniqueness keeps `:worker` in `fields`** — omit `fields` (default `[:args, :queue, :worker]`) or use `[:worker, :args]`; narrow with `keys:`, pick a state group such as `:incomplete`. `Oban.insert_all/2` ignores `unique` in OSS
6. **One `config :my_app, Oban` block with the 2.24 service keys** — `cron:`, `pruner:`, `lifeline:`; always enable `pruner` and `lifeline`
7. **Args hold IDs and small JSON values only** — fetch fresh data in `perform/1`
8. **Bound every job** — `timeout/1` for long work; outbound HTTP uses `retry: false` and a host allowlist; cap snoozes with `meta["snoozed"]`
9. **Test with `Oban.Testing`** — `testing: :manual`, `perform_job/3`, `assert_enqueued`, `drain_queue`; never call `perform/1` directly
10. **Workflows, Batches, global and rate limits, DynamicCron and bulk unique inserts are Oban Pro** — don't write OSS code that assumes them

---

## Worker definition

```elixir
defmodule MyApp.Workers.SendWelcomeEmail do
  use Oban.Worker,
    queue: :mailers,
    max_attempts: 5,
    unique: [period: {5, :minutes}, keys: [:user_id]]

  alias MyApp.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      nil -> {:cancel, :user_not_found}
      %{welcome_sent_at: %DateTime{}} -> :ok
      user -> Accounts.deliver_welcome(user)
    end
  end
end
```

- `Accounts.get_user/1` is `Repo.get(User, id)`, which you add; the generator only has `get_user!/1`, which would raise (and retry) for a deleted user instead of cancelling.
- `max_attempts` counts the first run (5 = 1 + 4 retries). Retries back off exponentially (15 s minimum, with jitter) unless you define `backoff/1`.
- `args` are stored as JSON: keys come back as strings, structs and tuples don't survive. Enqueue `%{user_id: user.id}`, never `%{user: user}`.
- `{:cancel, reason}` replaces the deprecated `{:discard, reason}`.

## Enqueuing

Enqueue from the context, in the transaction that writes the data. If the transaction rolls back, the job is never inserted; if it commits, the job can't run before the row exists:

```elixir
# The generated register_user/1 plus the job. If you added a registration_changeset/3
# (the phoenix-auth-customization skill), insert with that instead of email_changeset/2.
def register_user(attrs) do
  Repo.transact(fn ->
    with {:ok, user} <- %User{} |> User.email_changeset(attrs) |> Repo.insert(),
         {:ok, _job} <- Oban.insert(SendWelcomeEmail.new(%{user_id: user.id})) do
      {:ok, user}
    end
  end)
end
```

The `Ecto.Multi` form, when steps are built dynamically:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:user, User.email_changeset(%User{}, attrs))
|> Oban.insert(:welcome_job, fn %{user: user} -> SendWelcomeEmail.new(%{user_id: user.id}) end)
|> Repo.transact()
```

- **Scheduling:** `SendReminder.new(args, scheduled_in: {1, :hour})` (`scheduled_in` is the documented name since 2.24; `schedule_in` still works) or `scheduled_at: datetime`.
- **Unique conflicts are not errors:** `Oban.insert/2` returns `{:ok, %Oban.Job{conflict?: true}}` for a duplicate.
- **Bulk:** `Oban.insert_all/2` (or `Oban.insert_all(multi, :jobs, changesets)`) inserts many jobs in one query and returns a list. It raises on an invalid changeset and, in OSS, **skips uniqueness checks**; use `Oban.insert/2` per job when uniqueness matters.

## Configuration (Oban 2.24)

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, mailers: 5, imports: 2],
  cron: [
    crontab: [
      {"0 2 * * *", MyApp.Workers.NightlyCleanup},
      {"*/15 * * * *", MyApp.Workers.SyncData, args: %{source: "api"}}
    ]
  ],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {30, :minutes}]

# config/test.exs: no queues or plugins run; jobs stay in the table for assertions
config :my_app, Oban, testing: :manual
```

- `cron:`, `pruner:`, `lifeline:` and `reindexer:` are top-level keys since 2.24 (`Oban.Plugins.Cron` is now `Oban.Cron`, and so on). The old `plugins: [...]` form still works.
- Keep the Oban config in one `config` call. Repeated calls deep-merge keyword lists, but a `plugins:` list containing one bare module (`Oban.Plugins.Lifeline`) isn't a keyword list, so a later `plugins:` replaces it and cron or pruning silently disappears.
- **Lifeline is off unless configured.** Without it, jobs orphaned in `executing` by a node restart stay there forever. It rescues purely by time, so `rescue_after` must exceed your longest job's `timeout/1`, or it re-runs jobs that are still executing.
- **Pruner** keeps `oban_jobs` from growing without bound; `max_age` accepts `{7, :days}`.
- Start Oban in `application.ex` with `{Oban, Application.fetch_env!(:my_app, Oban)}`, before the Endpoint.

## Timeouts and backoff

```elixir
@impl Oban.Worker
def timeout(_job), do: to_timeout(minute: 2)

@impl Oban.Worker
def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)
```

- `timeout/1` returns **milliseconds** and defaults to `:infinity`. A timed-out job fails with `Oban.TimeoutError` and is retried like any error.
- `backoff/1` returns **seconds** until the next attempt.

## Idempotency

<!-- epg:bad -->
```elixir
# Sends a duplicate email whenever the job is retried or rescued
def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
  user = MyApp.Accounts.get_user!(user_id)
  MyApp.Mailer.send_welcome(user)
end
```

The worker above checks `welcome_sent_at` and `Accounts.deliver_welcome/1` sets it after sending. For external APIs that support it, send an idempotency key that stays the same across retries, e.g. `headers: [{"idempotency-key", "order-#{order.id}-charge"}]`, so a retry after a timeout can't charge twice.

Long data backfills that outgrow a migration fit a self-re-enqueuing batch worker; see the `ecto-migrations-safety` skill for the batching query.

## Uniqueness

```elixir
use Oban.Worker,
  queue: :sync,
  unique: [period: :infinity, keys: [:account_id], states: :incomplete]
```

- `fields` defaults to `[:args, :queue, :worker]`. Listing `[:args]` alone makes jobs from **different workers** with the same args collide.
- `states` groups (2.20+): `:successful` (default: everything except cancelled/discarded, so a completed job blocks duplicates for the whole `period`), `:incomplete` (available, scheduled, executing, retryable, suspended: "one at a time"), `:all`. A hand-written list such as `[:available, :scheduled, :executing]` misses `:retryable`, letting a duplicate in while a job waits to retry.
- Emails and notifications: the default states with a `period`. Syncs and imports: `states: :incomplete`.

## HTTP workers

```elixir
defmodule MyApp.Workers.FetchFeed do
  use Oban.Worker, queue: :http, max_attempts: 10

  @allowed_hosts ~w(api.example.com feeds.example.org)
  @max_snoozes 5

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(second: 30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}, meta: meta}) do
    with :ok <- check_host(url) do
      case Req.get(url, retry: false, redirect: false) do
        {:ok, %Req.Response{status: 200, body: body}} -> MyApp.Feeds.import(body)
        {:ok, %Req.Response{status: status}} when status in [404, 410] -> {:cancel, {:gone, status}}
        {:ok, %Req.Response{status: 429} = resp} -> snooze(resp, meta)
        {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
        {:error, exception} -> {:error, exception}
      end
    end
  end

  defp check_host(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in @allowed_hosts -> :ok
      _other -> {:cancel, :host_not_allowed}
    end
  end

  defp snooze(resp, meta) do
    if Map.get(meta, "snoozed", 0) >= @max_snoozes do
      {:error, :rate_limited}
    else
      {:snooze, retry_after(resp)}
    end
  end

  defp retry_after(resp) do
    resp
    |> Req.Response.get_header("retry-after")
    |> List.first("")
    |> Integer.parse()
    |> case do
      {seconds, ""} when seconds > 0 -> min(seconds, 3600)
      _missing_or_http_date -> 60
    end
  end
end
```

- **SSRF:** a URL from args can point at internal services or cloud metadata. Check the host against an allowlist and disable redirects (`redirect: false`), which could otherwise leave the allowlist.
- **`retry: false`:** Req retries GET/HEAD requests on 408/429/500/502/503/504 and transport errors by default (3 retries, sleeping for an uncapped `Retry-After`), multiplying Oban's own attempts and blocking the queue slot. For the client module itself (Req options, timeouts, capping Retry-After, Req.Test wiring), see the `http-clients-req` skill.
- **Match every status:** a `case` without a fallback clause raises `CaseClauseError` on the first unexpected status.
- **Snoozes (2.24):** a snooze no longer consumes an attempt, so `max_attempts` can't stop a job that keeps snoozing, and `attempt`-based delays stay constant. Count snoozes with `meta["snoozed"]` and stop after a limit. `{:snooze, period}` accepts seconds or `{5, :minutes}`.

## Testing

```elixir
defmodule MyApp.Workers.SendWelcomeEmailTest do
  use MyApp.DataCase, async: true
  use Oban.Testing, repo: MyApp.Repo

  import MyApp.AccountsFixtures

  alias MyApp.Workers.{FetchFeed, SendWelcomeEmail}

  test "registering a user enqueues the welcome email" do
    {:ok, user} = MyApp.Accounts.register_user(valid_user_attributes())
    assert_enqueued worker: SendWelcomeEmail, args: %{user_id: user.id}
  end

  test "sends the email" do
    user = user_fixture()
    assert {:ok, _user} = perform_job(SendWelcomeEmail, %{user_id: user.id})
  end

  test "cancels for a missing user" do
    assert {:cancel, :user_not_found} = perform_job(SendWelcomeEmail, %{user_id: -1})
  end

  test "cancels URLs outside the allowlist" do
    assert {:cancel, :host_not_allowed} =
             perform_job(FetchFeed, %{url: "http://169.254.169.254/latest/meta-data"})
  end
end
```

- `perform_job/3` stringifies args, validates the worker's options, checks the return value, and accepts job options such as `attempt: 10` or `meta: %{"snoozed" => 5}` to exercise last-attempt and snooze-cap branches.
- `Oban.drain_queue(queue: :mailers)` runs the queue's available jobs in the test process and returns `%{success: n, failure: n, ...}`; add `with_recursion: true` when jobs enqueue jobs and `with_scheduled: true` to include scheduled ones.
- `Oban.Testing.with_testing_mode(:inline, fn -> ... end)` runs jobs immediately inside one test; `assert_enqueued` can't see inline jobs because they're never inserted.
- `assert_enqueued worker: SendReminder, scheduled_in: {1, :hour}` (2.24) asserts relative schedules.

Tests that reach the HTTP call need a stub: let the worker merge test-only Req options (e.g. `plug: {Req.Test, MyApp.Workers.FetchFeed}`) from config, and define responses with `Req.Test.stub/2`. See the `testing-essentials` skill.

## Oban OSS vs Oban Pro

Available only in Oban Pro (licensed): Workflows (job dependencies, fan-out/fan-in), Batches with callbacks, the Smart Engine's global concurrency, rate limiting, queue partitioning and bulk unique `insert_all`, DynamicCron/DynamicQueues, Pro Lifeline. In OSS, build sequencing by enqueuing the next job at the end of `perform/1`, and limit concurrency with the queue's local limit.
