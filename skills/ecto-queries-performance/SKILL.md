---
name: ecto-queries-performance
description: "Use when a query is slow, N+1 or hard to compose — preload vs join-preload, dynamic/2, subquery/exists, Repo.aggregate, Repo.stream, FOR UPDATE, optimistic_lock, insert_all, Repo.explain, indexes, prepare_query. Not for schemas or scoped contexts (use ecto-essentials)."
---

# Ecto Queries & Performance

> Verified against Elixir 1.20, Phoenix 1.8, Ecto 3.14, ecto_sql 3.14 (PostgreSQL 16) — October 2026

## RULES — Follow these with no exceptions

1. **Preload in the context, once for the whole list.** Use `preload:` in the query or one `Repo.preload(list, ...)`. Never call `Repo.preload`, `Repo.get` or a context function per row, whether in `Enum.map`, a HEEx `:for` or a JSON view.
2. **Use separate-query preloads by default.** Join-preload only a `belongs_to`/`has_one` that you also filter or sort on. Joining a `has_many` multiplies rows, and `limit` then counts children instead of parents.
3. **A `limit` in a preload query is global, not per parent.** For "latest N per post", use a `row_number()` window restricted to the parents' ids.
4. **Count and check without loading rows.** Use `Repo.aggregate(q, :count)`, `Repo.exists?/1`, `group_by` + `count()`, or `select_merge` into a virtual field. Never `length(Repo.all(q))`.
5. **Compose with named bindings and `dynamic/2`.** Put `as:` on joins and use `with_named_binding/3` so a join is added only once. For "has any child", use `exists/1` with `parent_as/1` instead of a join plus `distinct`.
6. **Run `Repo.stream` only inside `Repo.transact`.** The function must return `{:ok, _}`, the transaction needs `timeout: :infinity`, and streams don't support preloads. For long jobs, batch by keyset (`where: p.id > ^last_id`), never `OFFSET`.
7. **Never read-modify-write a counter or balance.** Use `update_all(inc: ...)`, a conditional `update_all`, `lock: "FOR UPDATE"` inside `Repo.transact`, or `optimistic_lock/3` with `stale_error_field:`.
8. **`insert_all` and `update_all` bypass changesets.** Nothing is validated and no timestamps are generated. Set `inserted_at`/`updated_at` yourself, and chunk so rows × fields stays under Postgres's 65,535 parameters.
9. **Measure, then index the query you actually run.** Use `Repo.explain(:all, q, analyze: true)` and the `[:my_app, :repo, :query]` telemetry. Put equality columns first in a composite index. A partial or expression index is only used when the query repeats its predicate or expression.
10. **Tenant isolation comes from the scope, passed explicitly.** `prepare_query/3` is only a guard that raises when the tenant option is missing. Never keep the tenant in the process dictionary.

Examples extend the Phoenix 1.8 generated `Blog.Post` with `belongs_to :user` (replacing `field :user_id, :id`) and `has_many :comments`.

---

## Spotting N+1

The usual cause is a query hidden inside a loop: a context call in a template, a `Repo.preload` per element, or a JSON view that loads data for each item.

<!-- epg:bad -->
```heex
<%!-- One COUNT query per post, on every render --%>
<div :for={{id, post} <- @streams.posts} id={id}>
  {post.title} ({Blog.count_comments(@current_scope, post)} comments)
</div>
```

<!-- epg:bad -->
```elixir
# One comments query per post
posts |> Enum.map(&Repo.preload(&1, :comments))
```

In dev, the repeats are easy to see in the log. The generated `config/dev.exs` sets `stacktrace: true` on the repo, so every query log line ends with `↳ Module.fun/arity, at: file:line`. The same caller and the same SQL repeating with a different `$1` is an N+1. To lock the fix in, assert a query count in a test (see the [query-count helper](reference.md#counting-queries-in-tests)).

```elixir
def list_posts_with_comment_counts(%Scope{} = scope) do
  counts = from c in Comment, group_by: c.post_id, select: %{post_id: c.post_id, n: count(c.id)}

  from(p in Post,
    where: p.user_id == ^scope.user.id,
    left_join: c in subquery(counts),
    on: c.post_id == p.id,
    # comment_count is `field :comment_count, :integer, virtual: true` on Post
    select_merge: %{comment_count: coalesce(c.n, 0)},
    order_by: [desc: p.inserted_at, desc: p.id]
  )
  |> Repo.all()
end
```

The template then renders `{post.comment_count}`. If a template or JSON view needs data, the context function that feeds it has to load it.

## Preloading: separate queries vs one join

```elixir
# Separate queries (default): 1 for posts, then 1 per association for the whole
# list. Independent preloads run in parallel outside a transaction.
Post
|> where(user_id: ^scope.user.id)
|> preload([:user, comments: :user])
|> Repo.all()

# Already have the list? One query per association, not per post:
Repo.preload(posts, comments: :user)

# Join-preload: one query. Right for belongs_to/has_one you filter or sort on.
from(p in Post,
  as: :post,
  join: u in assoc(p, :user),
  as: :author,
  where: p.status == :published,
  order_by: [asc: u.email, desc: p.published_at],
  preload: [user: u]
)
|> Repo.all()
```

| Use | When |
|---|---|
| `preload: [:comments]` (separate query) | `has_many`/`many_to_many`, paginated parents, nested preloads |
| `join` + `preload: [user: u]` | `belongs_to`/`has_one` you also `where`/`order_by` on, so the join is needed anyway |
| `preload: [comments: ^query]` | Filter or order the children (`where: is_nil(c.deleted_at)`, `order_by: c.inserted_at`) |
| `preload_order: [asc: :inserted_at]` on `has_many` | A default child order, used when the preload query has no `order_by` of its own |

**Join-preloading a `has_many` with `limit`:** `from p in Post, join: c in assoc(p, :comments), preload: [comments: c], limit: 3` returns **one** post with three comments, because the limit applies to the joined rows. Paginate the parents, then preload the children with separate queries.

`Repo.preload/3` skips associations that are already loaded. Pass `force: true` to reload them after a write.

### Top N children per parent

A preload query's `limit` applies to all parents together. `preload: [comments: ^from(c in Comment, limit: 2)]` returns two comments in total, not two per post. Rank the children with a window function instead, and filter the ranking to the parents you already have so it doesn't scan the whole table:

```elixir
def preload_latest_comments(posts, n) do
  post_ids = Enum.map(posts, & &1.id)

  ranked =
    from c in Comment,
      where: c.post_id in ^post_ids,
      select: %{id: c.id, rank: over(row_number(), :per_post)},
      windows: [per_post: [partition_by: c.post_id, order_by: [desc: c.inserted_at]]]

  latest = from c in Comment, join: r in subquery(ranked), on: c.id == r.id and r.rank <= ^n

  Repo.preload(posts, comments: latest)
end
```

## Composable queries

Name every binding that other functions will refer to (`as: :post`, `as: :author`). Positional bindings break as soon as a join is added in a different order.

```elixir
def search_posts(%Scope{} = scope, params) do
  from(p in Post, as: :post, where: p.user_id == ^scope.user.id)
  |> maybe_join_author(params)
  |> where(^post_filters(params))
  |> order_by([post: p], desc: p.inserted_at, desc: p.id)
  |> Repo.all()
end

# Allowlist of keys; anything else is ignored. dynamic/2 builds the WHERE.
# Every named binding a dynamic uses must already be joined when where/2 runs,
# otherwise it raises "unknown bind name `:author`" — so join first.
defp post_filters(params) do
  Enum.reduce(params, dynamic(true), fn
    {"status", status}, dyn when status in ~w(draft published) ->
      dynamic([post: p], ^dyn and p.status == ^status)

    {"q", term}, dyn ->
      pattern = "%" <> escape_like(term) <> "%"
      dynamic([post: p], ^dyn and (ilike(p.title, ^pattern) or ilike(p.body, ^pattern)))

    {"author_email", email}, dyn ->
      dynamic([author: a], ^dyn and a.email == ^email)

    {"commented", "true"}, dyn ->
      dynamic([post: p], ^dyn and exists(from c in Comment, where: c.post_id == parent_as(:post).id))

    _other, dyn ->
      dyn
  end)
end

defp maybe_join_author(query, %{"author_email" => _}) do
  with_named_binding(query, :author, fn query, binding ->
    join(query, :inner, [post: p], a in assoc(p, :user), as: ^binding)
  end)
end

defp maybe_join_author(query, _params), do: query
```

- `escape_like/1` is in the `ecto-essentials` skill. Unescaped `%` or `_` in a search term match everything.
- `exists/1` takes a query directly, as in `exists(from c in Comment, ...)`. `exists(subquery(...))` also compiles. It must reference the outer row through `parent_as(:post)`, so the outer query needs `as: :post`. Use `not exists(...)` for "posts with no comments".
- `has_named_binding?/2` returns whether a binding exists, and `with_named_binding/3` adds a binding only if it is missing. The join above runs at most once, however many filters need it.
- Use `subquery/1` to aggregate first and then join, as in the comment counts above. Joining the raw children and then using `group_by` on the parent also works, but it can't be combined with preloads cleanly.

## Counting without loading

```elixir
Repo.aggregate(from(p in Post, where: p.user_id == ^scope.user.id), :count)
Repo.exists?(from c in Comment, where: c.post_id == ^post.id)

from(p in Post, where: p.user_id == ^scope.user.id, group_by: p.status, select: {p.status, count()})
|> Repo.all()
|> Map.new()
#=> %{draft: 4, published: 5}
```

- `count()` with no argument is `count(*)`. `count(c.id)` skips NULLs, which matters with a `left_join`.
- `Repo.aggregate/3` drops `order_by` and preloads, and wraps a query that has `limit`, `offset` or `distinct` in a subquery, so `Repo.aggregate(from(p in Post, limit: 2), :count)` returns 2, not the table count. It raises on a query with `group_by`; use the `group_by` + `select` form above.
- Use `Repo.exists?/1` for `if count > 0` checks. It stops at the first matching row.

## Large result sets

```elixir
def export_posts(%Scope{} = scope, device) do
  query = from p in Post, where: p.user_id == ^scope.user.id, order_by: p.id

  Repo.transact(
    fn ->
      query
      |> Repo.stream(max_rows: 1_000)
      |> Stream.chunk_every(1_000)
      |> Stream.flat_map(&Repo.preload(&1, :comments))
      |> Stream.each(&IO.binwrite(device, csv_line(&1)))
      |> Stream.run()

      {:ok, :exported}
    end,
    timeout: :infinity
  )
end
```

- Enumerating a stream outside a transaction raises `cannot reduce stream outside of transaction`.
- `Repo.transact/2` raises `ArgumentError` unless the function returns `{:ok, _}` or `{:error, _}`. The `Repo.stream` docs' own example returns `Enum.to_list(stream)` and would hit this error.
- `preload:` on a streamed query raises `preloads are not supported on streams`. Chunk the stream and call `Repo.preload/2` per chunk, as above.
- `max_rows` defaults to 500. The transaction's default 15 s timeout applies to the whole stream, so pass `timeout: :infinity`, or a real limit.
- A long-lived transaction holds a snapshot, which blocks vacuum and keeps locks. For backfills and jobs, process keyset batches, each in its own short query:

```elixir
def touch_all_posts(last_id \\ 0) do
  ids = Repo.all(from p in Post, where: p.id > ^last_id, order_by: p.id, limit: 1_000, select: p.id)

  case ids do
    [] ->
      :done

    ids ->
      now = DateTime.utc_now(:second)
      Repo.update_all(from(p in Post, where: p.id in ^ids), set: [updated_at: now])
      touch_all_posts(List.last(ids))
  end
end
```

`OFFSET n` makes Postgres read and discard n rows on every page, and rows that change between pages are skipped or repeated. Keyset pagination for UIs and APIs, with an `(inserted_at, id)` cursor, is covered in the `phoenix-json-api` skill. Run backfills outside migrations; see the `ecto-migrations-safety` skill.

## Concurrency and correctness

**Counters: one atomic statement.** Reading a value, adding to it in Elixir and writing it back loses updates under concurrency.

```elixir
from(p in Post, where: p.id == ^post.id)
|> Repo.update_all(inc: [comments_count: 1], set: [updated_at: DateTime.utc_now(:second)])
# UPDATE posts SET comments_count = comments_count + 1, updated_at = $1 WHERE id = $2
```

**Counter cache with `prepare_changes/2`.** The function runs inside the insert's transaction, and only when the changeset is valid:

```elixir
def create_comment(%Scope{} = scope, %Post{} = post, attrs) do
  post
  |> Ecto.build_assoc(:comments)
  |> Comment.changeset(attrs, scope)
  |> Ecto.Changeset.prepare_changes(fn changeset ->
    post_id = Ecto.Changeset.get_field(changeset, :post_id)
    changeset.repo.update_all(from(p in Post, where: p.id == ^post_id), inc: [comments_count: 1])
    changeset
  end)
  |> Repo.insert()
end
```

`post` must come from a scoped lookup (`get_post!(scope, id)`, or whatever posts this user may comment on). Never cast `post_id`.

**Conditional update** when the rule involves a single row: the `WHERE` enforces it atomically, without a lock.

```elixir
{count, _} =
  from(w in Wallet, where: w.id == ^wallet.id and w.balance >= ^amount)
  |> Repo.update_all(inc: [balance: -amount])

if count == 1, do: :ok, else: {:error, :insufficient_funds}
```

**`FOR UPDATE`** when the decision needs application logic across reads. The lock only lasts as long as the transaction:

```elixir
def transfer(%Scope{} = scope, from_id, to_id, amount) do
  Repo.transact(fn ->
    # One statement ordered by id: concurrent transfers lock rows in the same order
    wallets =
      from(w in Wallet, where: w.id in ^[from_id, to_id], order_by: w.id, lock: "FOR UPDATE")
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    from_wallet = Map.fetch!(wallets, from_id)
    to_wallet = Map.fetch!(wallets, to_id)
    true = from_wallet.user_id == scope.user.id

    # check_limits/2 returns :ok or {:error, reason}; any {:error, _} rolls back
    with :ok <- check_limits(from_wallet, amount),
         {:ok, _} <- Repo.update(Wallet.debit_changeset(from_wallet, amount)),
         {:ok, _} <- Repo.update(Wallet.credit_changeset(to_wallet, amount)) do
      {:ok, :transferred}
    end
  end)
end
```

Two transactions that lock the same rows in different orders deadlock, so lock them in one ordered statement as above (or always in id order).

**`FOR UPDATE SKIP LOCKED`** lets workers claim rows without blocking each other: `from(j in Job, where: j.state == "available", order_by: j.id, limit: 10, lock: "FOR UPDATE SKIP LOCKED")` inside `Repo.transact`. For background jobs, use Oban (see the `oban-essentials` skill) rather than building your own queue.

**Optimistic locking** for records edited in forms, where two users saving the same post must not silently overwrite each other. Add `add :lock_version, :integer, default: 1, null: false` to the table and `field :lock_version, :integer, default: 1` to the schema:

```elixir
def update_post(%Scope{} = scope, %Post{} = post, attrs) do
  true = post.user_id == scope.user.id

  post
  |> Post.changeset(attrs, scope)
  |> Ecto.Changeset.optimistic_lock(:lock_version)
  |> Repo.update(stale_error_field: :lock_version)
end
```

- Without `stale_error_field:`, a stale update raises `Ecto.StaleEntryError`. With it, the update returns `{:error, changeset}` with `lock_version: {"is stale", [stale: true]}`. The field has no input, so show that error in a flash ("changed by someone else — reload").
- The version comes from the struct you pass in. A LiveView keeps the post it loaded in `mount`, which is the right version. After a successful save, keep the returned post, which has the incremented version.

## Bulk writes with `insert_all`

```elixir
# Migration: create unique_index(:posts, [:user_id, :slug])
def import_posts(%Scope{} = scope, rows) do
  now = DateTime.utc_now(:second)

  entries =
    Enum.map(rows, fn row ->
      %{
        title: row.title,
        body: row.body,
        slug: row.slug,
        user_id: {:placeholder, :user_id},
        inserted_at: {:placeholder, :now},
        updated_at: {:placeholder, :now}
      }
    end)

  Repo.transact(fn ->
    total =
      entries
      |> Enum.chunk_every(5_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          Repo.insert_all(Post, chunk,
            placeholders: %{now: now, user_id: scope.user.id},
            on_conflict: {:replace, [:title, :body, :updated_at]},
            conflict_target: [:user_id, :slug]
          )

        acc + count
      end)

    {:ok, total}
  end)
end
```

- **No timestamps.** `insert_all` doesn't autogenerate `inserted_at`/`updated_at`, or any field except an `:id`/`:binary_id` primary key. With `null: false` columns, leaving them out fails with `not_null_violation`.
- **No changesets.** Values are dumped to their types, but nothing is validated. Validate user-supplied rows first, for example with a changeset and `apply_action/2`, and set `user_id` from the scope, never from the row.
- **65,535 bind parameters per statement.** Going over raises `postgresql protocol can not handle N parameters`. Each placeholder is sent once, whatever the number of rows, so chunk by `div(65_535, fields_not_in_placeholders)`. Smaller chunks (1k–5k rows) keep locks and memory reasonable.
- **`returning:`** returns structs for the rows written. With `on_conflict: :nothing`, skipped rows are not returned. With `{:replace, fields}`, updated rows are returned too.
- `conflict_target` must match a unique index exactly. Never include the conflict-target columns in `{:replace, ...}`. Upserts through a changeset (`Repo.insert/2`) are covered in the `ecto-essentials` skill.

## Measuring

```elixir
query = from p in Post, where: p.user_id == ^user_id and is_nil(p.deleted_at), order_by: [desc: p.published_at]

Repo.explain(:all, query, analyze: true, buffers: true) |> IO.puts()
# Index Scan Backward using posts_user_id_published_at_index on posts p0 ...

Repo.to_sql(:all, query)
#=> {"SELECT ... WHERE ((p0.\"user_id\" = $1) AND (p0.\"deleted_at\" IS NULL)) ...", [42]}
```

- `Repo.explain/3` is the same as `Ecto.Adapters.SQL.explain(Repo, ...)`. It takes `:all`, `:update_all` or `:delete_all`, and the Postgres options `analyze`, `verbose`, `costs`, `settings`, `buffers`, `timing`, `summary`, `format` (`:text`, `:map`, `:yaml`) and `plan`.
- `analyze: true` executes the query. By default it runs inside a transaction that is rolled back, so analyzing `update_all` is safe. **Inside your own `Repo.transact`, that forced rollback aborts your transaction.** Pass `wrap_in_transaction: false` there. The result then comes back as `{:ok, plan}`.
- Run EXPLAIN against production-sized data. On a dev table with ten rows, Postgres picks a sequential scan regardless of your indexes.
- In production, watch `[:my_app, :repo, :query]` telemetry (`total_time`, `queue_time`) for slow queries and pool pressure; see the `telemetry-essentials` skill. For copy-pasteable SQL with inlined params in dev, the `ecto_dev_logger` package replaces the default logger: set `log: false` on the repo in dev and call `Ecto.DevLogger.install(MyApp.Repo)`.

## Indexes for the queries you run

| Query shape | Index |
|---|---|
| `where user_id = ? order by published_at desc` | `index(:posts, [:user_id, :published_at])`: equality columns first, then the sort or range column |
| Same, plus `is_nil(p.deleted_at)` on every read | `index(:posts, [:user_id, :published_at], where: "deleted_at IS NULL")`: smaller, and only used when the query includes `deleted_at IS NULL` |
| `where state = 'available'` on a mostly-processed table | `index(:jobs, [:inserted_at], where: "state = 'available'")` |
| `fragment("lower(?)", u.email) == ^String.downcase(email)` | `index(:users, ["(lower(email))"], name: :users_lower_email_index)`: the query must use the same expression (or use `citext`) |
| Keyset `(inserted_at, id)` cursor | `index(:posts, [:user_id, :inserted_at, :id])` |

A composite index on `[:user_id, :published_at]` also serves queries on `user_id` alone, but not queries on `published_at` alone. Every foreign key needs its own index (or must lead a composite one) for joins and `on_delete`. Add indexes to large tables with `concurrently: true`; see the `ecto-migrations-safety` skill, and the `ecto-essentials` skill for basic index and constraint syntax.

## Multi-tenancy

**Row-level tenancy (an `org_id` column)** is what Phoenix 1.8 scopes are for. Context functions take the scope and filter explicitly, as in the `ecto-essentials` skill. A repo `prepare_query/3` callback can add a guard, so a forgotten filter raises instead of leaking. The callback is `prepare_query(operation, query, opts)` and returns `{query, opts}`. It raises when a schema with an `org_id` field is queried without `org_id:`, and adds `where(org_id: ^org_id)` when the option is given. Contexts then call `Repo.all(query, org_id: scope.org.id)`. Full code and a coverage table are in the [guard reference](reference.md#prepare_query3-guard).

- It runs for `all`/`get`/`one`/`aggregate`/`exists?`/`stream`/`update_all`/`delete_all`, but **not** for `insert`, `update` or `delete` of a struct. Writes still need the scope check.
- Options reach preload queries, so preloaded tenant tables are filtered too. Joins, subquery sources and bare table strings are **not** filtered.
- Migrations query with `schema_migration: true`, so the guard must let those through.
- Take the tenant from `scope` and pass it as an option. Don't store it in the process dictionary for `default_options/1` to read: it is invisible in the code, and it is lost in parallel preloads, `Task`s and LiveView `assign_async`, which all run in other processes.

**Schema-per-tenant (Postgres schemas)** is covered in the [multi-tenancy reference](reference.md#schema-per-tenant-prefixes): `prefix:` and `put_query_prefix/2` at runtime, and `@schema_prefix` only for fixed schemas.

## Testing

When writing tests for query performance (query counts, lock behavior), invoke `elixir-phoenix-guide:testing-essentials` before writing any `_test.exs` file. The query-count helper is in the [reference](reference.md#counting-queries-in-tests).
