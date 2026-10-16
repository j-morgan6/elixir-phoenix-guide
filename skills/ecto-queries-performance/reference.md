# Ecto Queries & Performance Reference

> Verified against Elixir 1.20, Ecto 3.14, ecto_sql 3.14 (PostgreSQL 16) — October 2026

Supporting material for the `ecto-queries-performance` skill.

## Counting queries in tests

This helper pins an N+1 fix by counting the `[:my_app, :repo, :query]` events that the code under test emits. Telemetry handlers are global and run in the process that issued the query, so the handler only counts queries from the test process and from processes that list it in `$callers`. That covers parallel preloads, `Task`s and LiveView async work, and it keeps `async: true` tests from counting each other's queries.

```elixir
# test/support/query_counter.ex
defmodule MyApp.QueryCounter do
  @event [:my_app, :repo, :query]

  @doc "Runs fun and returns {query_count, result}."
  def count_queries(fun) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, {self(), ref})

    try do
      result = fun.()
      {collect(ref, 0), result}
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def handle_event(_event, _measurements, _metadata, {pid, ref}) do
    if self() == pid or pid in Process.get(:"$callers", []), do: send(pid, {ref, :query})
  end

  defp collect(ref, count) do
    receive do
      {^ref, :query} -> collect(ref, count + 1)
    after
      0 -> count
    end
  end
end
```

```elixir
test "list_posts_with_comments/1 doesn't query per post", %{scope: scope} do
  for _ <- 1..5, do: post_fixture(scope)

  {count, posts} = MyApp.QueryCounter.count_queries(fn -> Blog.list_posts_with_comments(scope) end)

  assert length(posts) == 5
  # posts + comments, whatever the number of posts
  assert count == 2
end
```

Verified behavior: `Repo.all(from p in Post, preload: [:comments, :user])` counts 3, mapping `Repo.preload/2` over 12 posts counts 13, and a query run inside `Task.async` is counted. The handler is a remote capture (`&__MODULE__.handle_event/4`), so `:telemetry` doesn't log its "local function" performance warning.

## Schema-per-tenant prefixes

Here each tenant gets a Postgres schema (`tenant_42.posts`), and the prefix is chosen at runtime from the scope:

```elixir
defp prefix(%Scope{} = scope), do: "tenant_#{scope.org.id}"

def list_posts(%Scope{} = scope) do
  Post
  |> order_by(desc: :inserted_at)
  |> Repo.all(prefix: prefix(scope))
end

def create_post(%Scope{} = scope, attrs) do
  %Post{}
  |> Post.changeset(attrs, scope)
  |> Repo.insert(prefix: prefix(scope))
end
```

- `Repo.all(query, prefix: p)` applies `p` to every `from` and `join` that doesn't already have a prefix. `put_query_prefix(query, p)` sets the same thing on the query itself, for example `Post |> put_query_prefix("tenant_1") |> preload(:comments)`, which generates `FROM "tenant_1"."posts"`.
- **Loaded structs remember their prefix** in `__meta__` (`Ecto.get_meta(post, :prefix)`). `Repo.update/2`, `Repo.delete/2` and `Repo.preload/2` on that struct go to the same schema without passing `prefix:` again. To build a new struct for a tenant, use `Ecto.put_meta(%Post{}, prefix: p)` or pass `prefix:` to `insert`.
- `@schema_prefix "analytics"` is a **compile-time** default for a schema that always lives in one fixed Postgres schema. It can't express per-tenant prefixes.
- Run tenant migrations with `mix ecto.migrate --prefix tenant_42`, or `Ecto.Migrator.run(Repo, :up, all: true, prefix: "tenant_42")` when you create a tenant at runtime. Every tenant schema has its own `schema_migrations` table.
- Build the prefix only from a trusted id (the scope's org id), never from request input. A prefix is interpolated into SQL as an identifier, not sent as a bind parameter.
- Hundreds of schemas multiply migration time and catalog size. Above a few hundred tenants, row-level `org_id` with the `prepare_query/3` guard from the skill usually scales better.

## `prepare_query/3` guard

This guard is for row-level tenancy. Every tenant table has an `org_id` column, and contexts pass `org_id: scope.org.id` to Repo calls. `tenant_schema?/1` runs first, so queries on non-tenant schemas (users, or Oban's tables) pass through untouched.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres

  require Ecto.Query

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:schema_migration] || not tenant_schema?(query) ->
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, org_id: ^org_id), opts}

      true ->
        raise ArgumentError, "expected :org_id or skip_org_id: true for #{inspect(query.from.source)}"
    end
  end

  defp tenant_schema?(%{from: %{source: {_table, schema}}}) when is_atom(schema) and not is_nil(schema),
    do: :org_id in schema.__schema__(:fields)

  defp tenant_schema?(_query), do: false
end

# In the context: Repo.all(query, org_id: scope.org.id)
```

### What it covers

This was checked against a test repo running the code above, with only the tenant column renamed:

| Call | Guarded? |
|---|---|
| `Repo.all/one/get/get_by/aggregate/exists?/stream`, `update_all`, `delete_all` on a tenant schema | Yes: raises without `org_id:`, filters with it |
| Preloads of tenant associations | Yes: the options propagate (`ecto_query: :preload`) |
| Preloads of non-tenant schemas (e.g. `:user`) | Skipped by `tenant_schema?/1`, so they work |
| Joined tenant tables | **No**: only the `from` source is filtered |
| `from` a subquery or a bare table string (`from p in "posts"`) | **No**: there is no schema to inspect |
| `Repo.insert/update/delete` of a struct | **No**: the callback isn't invoked; check ownership against the scope |

## Reading EXPLAIN output

- `Seq Scan` on a large table, combined with a selective `WHERE`, usually means a missing index, or an index the predicate can't use (different expression, missing partial-index predicate, leading column not in the `WHERE`).
- `Sort` above an `Index Scan` means the index serves the filter but not the `ORDER BY`. Add the sort column after the equality columns.
- With `analyze: true`, a large gap between estimated `rows=` and actual rows points to stale statistics: run `ANALYZE posts`.
- `buffers: true` shows `shared hit` (cache) versus `read` (disk). Queries that read many pages are the ones to fix first.
- `format: :map` returns the plan as decoded JSON, which is handy for asserting on it in a script.
