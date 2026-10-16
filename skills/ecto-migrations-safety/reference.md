# Ecto Migrations Safety — Reference

Extra detail for the `ecto-migrations-safety` skill. Verified against ecto_sql 3.14 and PostgreSQL 16.

## lock_timeout for a concurrent index

`CREATE INDEX CONCURRENTLY` can't run in a transaction, so `after_begin/0` never runs and `SET LOCAL` has nothing to attach to. Without a transaction, each migration command checks out whichever pooled connection is free, so a session-level `SET` reaches only some of them. Pin one connection for the whole migration:

```elixir
defmodule MyApp.Repo.Migrations.AddPostsSlugIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    with_lock_timeout(fn -> create index(:posts, [:slug], concurrently: true) end)
  end

  def down do
    with_lock_timeout(fn -> drop index(:posts, [:slug], concurrently: true) end)
  end

  # Pin one connection so the SET applies to the DDL that follows.
  defp with_lock_timeout(fun) do
    repo().checkout(fn ->
      repo().query!("SET lock_timeout TO '5s'")

      try do
        fun.()
        flush()
      after
        repo().query!("RESET lock_timeout")
      end
    end)
  end
end
```

- This needs `up/0`/`down/0`: `flush()` inside `change/0` raises on rollback.
- Tested: while another session held `SHARE UPDATE EXCLUSIVE` on `posts`, the build failed after the timeout with `55P03` and left no index behind.
- A queued concurrent build doesn't block reads or writes, because `SHARE UPDATE EXCLUSIVE` doesn't conflict with them. So this is optional. Use it when a stalled deploy is worse than a failed one.

## Applying lock_timeout to every migration

This is the pattern from the `Ecto.Migration` docs:

```elixir
defmodule MyApp.Migration do
  defmacro __using__(_opts) do
    quote do
      use Ecto.Migration

      def after_begin do
        repo().query!("SET LOCAL lock_timeout TO '5s'")
      end
    end
  end
end
```

Put it in `lib/my_app/migration.ex` and write `use MyApp.Migration` in place of `use Ecto.Migration`. `mix ecto.gen.migration` still generates `use Ecto.Migration`, so change it in each new file. Migrations with `@disable_ddl_transaction` skip `after_begin/0`.

## Migration lock strategies (PostgreSQL adapter)

| `migration_lock` | Behaviour |
|---|---|
| `:table_lock` (default) | opens a transaction and runs `LOCK TABLE "schema_migrations" IN SHARE UPDATE EXCLUSIVE MODE` for the run. Concurrent index builds deadlock against it unless the migration sets `@disable_migration_lock true` |
| `:pg_advisory_lock` | holds `pg_try_advisory_lock(...)` on one connection. Other nodes retry every 5 s (`:migration_advisory_lock_retry_interval_ms`) without limit (`:migration_advisory_lock_max_tries`). Doesn't work behind PgBouncer in transaction or statement pooling mode |
| `false` | no lock at all |

## Lock levels for common DDL (PostgreSQL docs)

| Statement | Lock | Conflicts with normal traffic |
|---|---|---|
| `ADD COLUMN`, `DROP COLUMN`, `ALTER COLUMN TYPE`, `SET NOT NULL`, `RENAME` | `ACCESS EXCLUSIVE` | reads and writes |
| `ADD CONSTRAINT ... CHECK`, including `NOT VALID` | `ACCESS EXCLUSIVE` | reads and writes, briefly when `NOT VALID` |
| `ADD FOREIGN KEY` | `SHARE ROW EXCLUSIVE` on both tables | writes |
| `VALIDATE CONSTRAINT` | `SHARE UPDATE EXCLUSIVE` (foreign keys: plus `ROW SHARE` on the referenced table) | none |
| `CREATE INDEX` | `SHARE` | writes |
| `CREATE INDEX CONCURRENTLY` / `DROP INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | none |
| `DROP INDEX` | `ACCESS EXCLUSIVE` | reads and writes |

Any of these, while it waits, also blocks every later request for a conflicting lock. That's why `lock_timeout` matters even for instant DDL.

## Checking for rewrites yourself

```sql
SELECT pg_relation_filenode('posts');   -- changes after a rewrite
SET client_min_messages TO debug1;      -- in psql, before the ALTER
-- "verifying table "posts""  => full scan
-- "existing constraints on column ... are sufficient to prove that it does not contain nulls"  => scan skipped
```

## Pre-merge checklist

- [ ] Each migration that alters a populated table sets `lock_timeout`
- [ ] Indexes on existing tables use `concurrently: true` with both attributes, one per migration
- [ ] No volatile defaults and no rewriting type changes on large tables
- [ ] New constraints and foreign keys use `validate: false`, validated in a later migration
- [ ] No rename or drop of anything the currently deployed code reads
- [ ] Backfills are separate, schemaless and batched
- [ ] `mix ecto.rollback` works for the new migrations (or `down/0` is deliberately a no-op)
- [ ] `mix ecto.migrate --log-migrations-sql` output reviewed
