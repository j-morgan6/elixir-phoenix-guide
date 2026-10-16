---
name: ecto-migrations-safety
description: "Use when migrating PostgreSQL tables that serve live traffic — index concurrently, @disable_ddl_transaction/@disable_migration_lock, lock_timeout, NOT NULL/foreign keys via NOT VALID, backfills, renames in rolling deploys. Not for migration basics (use ecto-essentials) or releases (use deployment-gotchas)."
---

# Ecto Migrations Safety

> Verified against Elixir 1.20, Ecto 3.14 (ecto_sql 3.14), PostgreSQL 16 — October 2026

## RULES — Follow these with no exceptions

1. **Index existing tables with `concurrently: true` plus both `@disable_ddl_transaction true` and `@disable_migration_lock true`**, one index per migration. With only the first, the migration hangs forever under the default migration lock.
2. **Set `lock_timeout` in every transactional migration that alters a busy table**: `after_begin/0` calling `repo().query!("SET LOCAL lock_timeout TO '5s'")`. Never `execute/1` there, because it breaks rollback of `change/0`.
3. **Add columns as nullable or with a constant default.** A volatile default (`gen_random_uuid()`, `clock_timestamp()`, `random()`) rewrites the whole table under an exclusive lock.
4. **`NOT NULL` takes three migrations**: `CHECK (col IS NOT NULL)` with `validate: false`, then `VALIDATE CONSTRAINT`, then `SET NOT NULL` through `execute/2`. Don't use `modify ... null: false` for this step: it also emits `ALTER COLUMN TYPE`, which rescans the table.
5. **Add foreign keys and check constraints to populated tables with `validate: false`**, then validate them in a later migration.
6. **Never rename or drop anything the running code reads.** Expand and contract across deploys. To rename only in Elixir, use `field :new_name, :string, source: :old_column`.
7. **Change a type in place only when PostgreSQL can skip the rewrite** (`varchar` → `text`). Any other change (`integer` → `bigint`) gets a new column, a backfill and a switch.
8. **Backfill in a separate data migration**: schemaless (`from p in "posts"`), batched, outside a DDL transaction. Never call app schemas or contexts from a migration.
9. **Make every migration reversible** (`execute/2`, `modify ... from:`, `remove/3` with a type) or write `up/0`/`down/0`. Keep migrations without a transaction to a single idempotent step, because they can fail half-applied.
10. **Run migrations before the new code takes traffic** (see the `deployment-gotchas` skill), and read the generated SQL with `mix ecto.migrate --log-migrations-sql` before you ship.

---

## Why "it worked locally" isn't enough: the lock queue

Most `ALTER TABLE` forms take an `ACCESS EXCLUSIVE` lock. On a busy table, the danger isn't how long the DDL takes. It's the time spent **waiting** for the lock: while an `ALTER` waits behind one long-running query or idle transaction, every later `SELECT` on that table queues behind the `ALTER`. A 2 ms change becomes a full outage. Two fixes cover most cases:

- don't hold the lock for long: no table rewrites, no full scans under `ACCESS EXCLUSIVE`
- don't wait for it for long: set `lock_timeout`, let the migration fail, and retry later

| Operation (PostgreSQL 12+) | Rewrite or scan? | Blocks reads and writes? |
|---|---|---|
| `add :col, :type` (nullable, no default) | no | briefly |
| `add :col, :type, default: "constant"` (constant default, even with `null: false`) | no | briefly |
| `add :col, :uuid, default: fragment("gen_random_uuid()")` | **rewrite** | for the whole rewrite |
| `modify :title, :text, from: :string` (varchar → text) | no | briefly |
| `integer` → `bigint`, or any other non-binary-compatible type | **rewrite** | for the whole rewrite |
| `SET NOT NULL` | **full scan**, unless a validated `CHECK (col IS NOT NULL)` exists | for the scan |
| `create constraint(..., validate: false)` / `references(..., validate: false)` | no | briefly |
| `VALIDATE CONSTRAINT` | scan | no (`SHARE UPDATE EXCLUSIVE`) |
| `create index` | scan | blocks writes for the build |
| `create index(..., concurrently: true)` | scan | no |
| `rename`, `remove` | no | briefly, **but breaks old code** |

The rewrite and scan rows were measured on a 2M-row table (relfilenode changes, `DEBUG` output). Lock levels come from the PostgreSQL `ALTER TABLE` docs.

## Concurrent indexes

```elixir
defmodule MyApp.Repo.Migrations.AddPostsSlugIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:posts, [:slug], concurrently: true)
  end
end
```

Rolling it back emits `DROP INDEX CONCURRENTLY`. Here is why both attributes are needed (each case tested):

| Attributes | Result |
|---|---|
| neither | `ERROR 25001 CREATE INDEX CONCURRENTLY cannot run inside a transaction block` |
| only `@disable_ddl_transaction` | **hangs forever.** The default `migration_lock: :table_lock` keeps a transaction open on `schema_migrations` for the whole run, while the migration runs in a separate process. `CREATE INDEX CONCURRENTLY` waits for every older transaction to finish, including that one (`wait_event = virtualxid`). Ecto only prints an `IO.warn` |
| both | works |
| only `@disable_ddl_transaction`, plus repo `migration_lock: :pg_advisory_lock` | works, no warning |

- `@disable_migration_lock true` lets two nodes run the same migration at the same time. That's fine when one pre-deploy job runs migrations. If every node migrates on boot, set `config :my_app, MyApp.Repo, migration_lock: :pg_advisory_lock` instead. It's session-level, so it doesn't work behind PgBouncer in transaction pooling mode.
- `concurrently` is only for tables that already hold data. An index in the same migration as `create table` needs neither attribute.
- **A failed concurrent build leaves an `INVALID` index behind.** For example, `create unique_index(..., concurrently: true)` fails on duplicate rows. Re-running the migration then fails with `42P07 relation "..." already exists`. Find it with `SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid`, run `DROP INDEX CONCURRENTLY name`, fix the data and migrate again.
- The build waits for long-running and idle-in-transaction sessions to finish. It doesn't block traffic while it waits, but the deploy stalls.

## lock_timeout

```elixir
defmodule MyApp.Repo.Migrations.AddPostsStatus do
  use Ecto.Migration

  def after_begin do
    repo().query!("SET LOCAL lock_timeout TO '5s'")
  end

  def change do
    alter table(:posts) do
      add :status, :string, default: "draft", null: false
    end
  end
end
```

If another session holds a conflicting lock for more than 5 s, the migration fails with `55P03 lock_not_available` and rolls back. The table is untouched; retry the deploy.

- `after_begin/0` runs right after the migration transaction opens, on `up` and on `down`. `SET LOCAL` limits the setting to that transaction. A plain `SET` would stay on the pooled connection.
- Use `repo().query!` and not `execute "SET ..."`. `after_begin/0` runs in the same direction as `change/0`, so on rollback Ecto tries to reverse the `execute/1` and raises `cannot reverse migration command`.
- `after_begin/0` **doesn't run** in `@disable_ddl_transaction` migrations, and a plain `repo().query!("SET lock_timeout ...")` there doesn't stick either: every command may check out a different pooled connection (tested: the setting alternated between two backends). Pin one connection with `repo().checkout/1`. See the [migrations safety reference](reference.md).
- To apply it to every migration, use the pattern from the `Ecto.Migration` docs: a `MyApp.Migration` module whose `__using__/1` does `use Ecto.Migration` and defines `after_begin/0`. Then `use MyApp.Migration` in each migration.
- Ecto runs migration DDL with no client timeout (`timeout: :infinity`), but a `statement_timeout` set on the database role still applies. If your role has one, scans like `VALIDATE` and index builds can be cancelled. Override it in that migration with `SET LOCAL statement_timeout TO 0`.

## NOT NULL on an existing column

```elixir
# 1. Enforced for new writes from now on; existing rows aren't checked
def change do
  create constraint(:posts, :posts_title_not_null, check: "title IS NOT NULL", validate: false)
end
```

```elixir
# 2. A separate migration, so the scan runs without the ACCESS EXCLUSIVE lock from step 1
def change do
  execute "ALTER TABLE posts VALIDATE CONSTRAINT posts_title_not_null", ""
end
```

```elixir
# 3. PostgreSQL 12+ sees the validated CHECK and skips the scan
def change do
  execute "ALTER TABLE posts ALTER COLUMN title SET NOT NULL",
          "ALTER TABLE posts ALTER COLUMN title DROP NOT NULL"

  execute "ALTER TABLE posts DROP CONSTRAINT posts_title_not_null",
          "ALTER TABLE posts ADD CONSTRAINT posts_title_not_null CHECK (title IS NOT NULL) NOT VALID"
end
```

- Backfill any `NULL`s before step 2, or `VALIDATE` fails.
- Steps 1 and 2 must be separate migrations. In one transaction, the `ACCESS EXCLUSIVE` lock from `ADD CONSTRAINT` is held for the whole validating scan.
- Step 3 measured: about 0.3 ms with `execute` against about 55 ms for `modify :title, :string, null: false, from: {:string, null: true}` on 2M rows. The `modify` form generates `ALTER COLUMN "title" TYPE varchar(255), ALTER COLUMN "title" SET NOT NULL`, and the `TYPE` clause makes PostgreSQL verify the table again.
- `drop constraint/2` can't be reversed in `change/0`, so step 3 uses `execute/2` for both statements.

## Foreign keys and check constraints

```elixir
# Migration 1: new column with a foreign key that skips the existing-rows check
alter table(:posts) do
  add :editor_id, references(:users, on_delete: :nilify_all, validate: false)
end
```

```elixir
# Migration 2
def change do
  execute "ALTER TABLE posts VALIDATE CONSTRAINT posts_editor_id_fkey", ""
end
```

- `references(..., validate: false)` generates `... REFERENCES "users"("id") ON DELETE SET NULL NOT VALID` (PostgreSQL only). Adding a validated foreign key locks out writes on **both** tables while it scans.
- For an existing column, `modify :reviewer_id, references(:users, validate: false), from: :bigint` works. It emits a no-op `ALTER COLUMN TYPE bigint` along with `ADD CONSTRAINT ... NOT VALID`.
- The constraint name is `<table>_<column>_fkey` unless you pass `name:`. `create constraint(..., check: ..., validate: false)` works the same way for check constraints.
- Indexing the new foreign key column is a separate concurrent-index migration.

## Renames, type changes, drops: expand and contract

During a rolling deploy, old instances run against the new schema. Ecto names every schema field in its SQL (`SELECT p0."id", p0."title" ...`), so a renamed or dropped column fails every query from old instances with `undefined_column`.

| Change | Steps (each one is its own deploy) |
|---|---|
| Rename a column | add the new column → write both → backfill → read the new one → stop writing the old one → drop it |
| Rename only in code | `field :headline, :string, source: :title`, no migration |
| Change a type (`integer` → `bigint`) | same as a rename: new column, dual-write, backfill, switch reads, drop |
| Drop a column | remove the field from the schema and deploy → drop the column in the next deploy |
| Rename a table | create the new table, dual-write and backfill, or keep the old name and set `schema "old_name"` |
| Add a `NOT NULL` column | add it nullable or with a constant default, so old code's inserts still work |

Dual writes go in the changeset or context function (`put_change/3` on both fields), not in a database trigger you'll forget to remove.

## Backfills

<!-- epg:bad -->
```elixir
# Breaks on a fresh database once Post gains a field this migration predates,
# and holds one transaction (and its row locks) for the whole update
def change do
  alter table(:posts), do: add(:slug, :text)
  flush()
  MyApp.Repo.update_all(MyApp.Blog.Post, set: [slug: "x"])
end
```

```elixir
defmodule MyApp.Repo.Migrations.BackfillPostSlugs do
  use Ecto.Migration
  import Ecto.Query

  @disable_ddl_transaction true
  @disable_migration_lock true
  @batch_size 10_000

  def up, do: backfill(0)

  def down, do: :ok

  defp backfill(last_id) do
    ids =
      repo().all(
        from(p in "posts",
          where: p.id > ^last_id and is_nil(p.slug),
          order_by: p.id,
          limit: @batch_size,
          select: p.id
        ),
        log: false
      )

    case ids do
      [] ->
        :ok

      ids ->
        repo().update_all(
          from(p in "posts", where: p.id in ^ids, update: [set: [slug: fragment("lower(?)", p.title)]]),
          [],
          log: false
        )

        backfill(List.last(ids))
    end
  end
end
```

- Each batch commits on its own, so row locks are short and a failure keeps the progress made so far. The `is_nil` filter makes a re-run continue where it stopped. Tested: 2M rows in about 11 s.
- Use the table name (`"posts"`), never `MyApp.Blog.Post`. Migrations run against the schema as it was at that version, and app modules change after the migration is written.
- Optional: keep data migrations in `priv/repo/data_migrations` and run them with `mix ecto.migrate --migrations-path priv/repo/data_migrations`, or `Ecto.Migrator.run(repo, Ecto.Migrator.migrations_path(repo, "data_migrations"), :up, all: true)` from your Release module. They share `schema_migrations`, so `mix ecto.migrations` lists their versions as `** FILE NOT FOUND **` unless you pass the path.
- For very large tables, or work that needs app logic (slugs that must be unique, external calls), enqueue an Oban job that processes batches and re-enqueues itself. See the `oban-essentials` skill.

## Reversibility and partial failure

The basics (`remove/3` with a type, `modify ... from:`, `execute/2`) are in the `ecto-essentials` skill. Specific to safe migrations:

- `drop constraint`, `remove_if_exists`, `execute/1` and `flush()` can't run backward inside `change/0`. `flush()` raises `calling flush() inside change when doing rollback is not supported`, so write `up/0` and `down/0`.
- `@disable_ddl_transaction` means no rollback on error. Ecto records the version only after the whole migration succeeds, so with two statements where the second fails, the first stays applied and the next run repeats it. Keep these migrations to one statement, or make every step idempotent (`create_if_not_exists`, `IF NOT EXISTS`).
- `mix ecto.migrate --step 1` applies one migration and `mix ecto.rollback` reverts one by default (`--step n`, `--to version`, `--all`). In production, roll back with the Release module's `rollback/2`.

## Tooling

- `mix ecto.migrate --log-migrations-sql` prints the SQL each migration command generates. `--log-migrator-sql` also prints the migrator's own `begin`/`LOCK TABLE`/advisory-lock statements. Run them against a dev copy before shipping.
- `mix ecto.migrations` shows which migrations are up and which are down.
- Hex linters such as `excellent_migrations` and `strong_migrations` flag many of these patterns in CI.
- ecto_sql 3.14's docs include a "Safe Ecto Migrations" guide with more recipes.

More recipes (lock_timeout for concurrent indexes, lock-level details, a pre-merge checklist) are in the [migrations safety reference](reference.md).
