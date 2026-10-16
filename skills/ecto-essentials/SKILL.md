---
name: ecto-essentials
description: "Use when defining schemas, writing queries, or creating migrations — scoped context functions, Repo.transact, upserts, indexes, query composition, safe field casting. Not for multi-changeset design (ecto-changeset-patterns) or nested children (ecto-nested-associations)."
---

# Ecto Essentials

> Verified against Elixir 1.20, Phoenix 1.8, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Scope every context function** — take `%Scope{}` first and filter by owner (`Repo.get_by!(Post, id: id, user_id: scope.user.id)`), as the Phoenix 1.8 generators do; never load, update or delete by a client-supplied id alone
2. **Never `cast` foreign keys or privileged fields** (`:user_id`, `:folder_id`, `:role`, `:org_id`, `:confirmed_at`, `:deleted_at`) — set them with `put_change`/`Ecto.build_assoc` after a scope-checked lookup; use the 1.8 `changeset(struct, attrs, scope)` shape
3. **Always use changesets** for inserts and updates — never pass raw maps to Repo
4. **Use `Repo.transact/2` with `with`** for multi-step writes; `Repo.transaction/2` is soft-deprecated since Ecto 3.13. Reach for `Ecto.Multi` only when the steps are dynamic (see the `ecto-nested-associations` skill)
5. **Preload associations** before accessing them — avoid N+1 queries
6. **Add database constraints AND changeset constraint functions** — `unique_index` + `unique_constraint`, `references` + `foreign_key_constraint`
7. **Index every foreign key** and every column you filter or sort on
8. **Use `timestamps(type: :utc_datetime)`** in schemas and migrations — matches Phoenix 1.8's `timestamp_type: :utc_datetime`
9. **Escape `%`, `_` and `\` in user search terms** before building a `like`/`ilike` pattern
10. **Keep `change/0` migrations reversible** — `remove/3` with the type, `modify` with `from:`, `execute/2` with an up and a down
11. **Database access goes through contexts** — never call `Repo` from controllers or LiveViews

---

## Schema and Changeset (1.8 scope pattern)

```elixir
defmodule MyApp.Media.Image do
  use Ecto.Schema
  import Ecto.Changeset

  schema "images" do
    field :title, :string
    # Server-generated storage name (UUID + allowlisted extension)
    field :filename, :string
    # The client's file name, for display only
    field :original_name, :string
    # Detected from the file's bytes, not the client's claim
    field :content_type, :string
    field :byte_size, :integer

    belongs_to :folder, MyApp.Media.Folder
    belongs_to :user, MyApp.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(image, attrs, scope) do
    image
    |> cast(attrs, [:title, :original_name])
    # filename/content_type/byte_size are set on the struct by the upload code
    # (see the phoenix-uploads skill); validate_required also checks struct data.
    |> validate_required([:title, :filename, :content_type, :byte_size])
    |> validate_length(:title, max: 255)
    |> put_change(:user_id, scope.user.id)
  end
end
```

This `Image` is the running example in the `phoenix-uploads`, `phoenix-liveview-essentials` (checklist) and `testing-essentials` (reference) skills too.

**Mass assignment:** anything in the `cast` list can be set from a form or JSON body (bad/good pair in the `ecto-changeset-patterns` skill). Set ownership from the scope and foreign keys from a record you loaded through the scope:

```elixir
def move_image(%Scope{} = scope, %Image{} = image, folder_id) do
  true = image.user_id == scope.user.id
  folder = get_folder!(scope, folder_id)

  image
  |> Ecto.Changeset.change(folder_id: folder.id)
  |> Ecto.Changeset.foreign_key_constraint(:folder_id)
  |> Repo.update()
end
```

## Context Pattern (scoped)

To generate this shape, or an org-scoped variant with `--scope org`, see the `phoenix-scopes-and-generators` skill.

Mirror `mix phx.gen.context` in 1.8: scope first, owner filter on every read, ownership assert on every write. (The generator also broadcasts `{:created | :updated | :deleted, image}` after each write; see the `phoenix-pubsub-patterns` skill.)

```elixir
defmodule MyApp.Media do
  import Ecto.Query, warn: false

  alias MyApp.Accounts.Scope
  alias MyApp.Media.{Folder, Image}
  alias MyApp.Repo

  # filters: [folder_id: id, search: term, min_size: bytes] (see Query Composition)
  def list_images(%Scope{} = scope, filters \\ []) do
    Image
    |> where(user_id: ^scope.user.id)
    |> filter_images(filters)
    |> order_by(desc: :inserted_at, desc: :id)
    |> Repo.all()
  end

  def get_image!(%Scope{} = scope, id) do
    Repo.get_by!(Image, id: id, user_id: scope.user.id)
  end

  def get_folder!(%Scope{} = scope, id) do
    Repo.get_by!(Folder, id: id, user_id: scope.user.id)
  end

  # tmp_path is the upload's temp file; store_file/1 checks its magic bytes,
  # names it on the server and copies it. Storage fields never go through cast.
  def create_image(%Scope{} = scope, tmp_path, attrs) do
    with {:ok, stored} <- store_file(tmp_path) do
      Image
      |> struct!(stored)
      |> Image.changeset(attrs, scope)
      |> Repo.insert()
    end
  end

  def update_image(%Scope{} = scope, %Image{} = image, attrs) do
    true = image.user_id == scope.user.id

    image
    |> Image.changeset(attrs, scope)
    |> Repo.update()
  end

  # For uploaded files, the phoenix-uploads version also removes the stored file.
  def delete_image(%Scope{} = scope, %Image{} = image) do
    true = image.user_id == scope.user.id
    Repo.delete(image)
  end

  # Private helpers not shown: filter_images/2 (Query Composition below) and
  # store_file/1 (the phoenix-uploads skill).
end
```

<!-- epg:bad -->
```elixir
# IDOR: any logged-in user can read or delete any image by guessing ids
def get_image!(id), do: Repo.get!(Image, id)
```

LiveViews and controllers pass `socket.assigns.current_scope` / `conn.assigns.current_scope`.

## Query Composition

```elixir
def search_images(%Scope{} = scope, term) do
  pattern = "%" <> escape_like(term) <> "%"

  Image
  |> where(user_id: ^scope.user.id)
  |> where([i], ilike(i.title, ^pattern) or ilike(i.original_name, ^pattern))
  |> order_by(desc: :inserted_at, desc: :id)
  |> Repo.all()
end

# `%` and `_` are LIKE wildcards; `\` is Postgres's default LIKE escape character.
# Unescaped, a search for "_" matches every row.
defp escape_like(term), do: String.replace(term, ["\\", "%", "_"], &("\\" <> &1))
```

Dynamic filters for `list_images(scope, filters)` above — reduce over an allowlist of keys; unknown keys fall through:

```elixir
defp filter_images(query, filters) do
  Enum.reduce(filters, query, fn
    {:folder_id, folder_id}, query -> where(query, [i], i.folder_id == ^folder_id)
    {:search, term}, query -> where(query, [i], ilike(i.title, ^"%#{escape_like(term)}%"))
    {:min_size, size}, query -> where(query, [i], i.byte_size >= ^size)
    _, query -> query
  end)
end
```

To get one row from a query that may match several, use `query |> first() |> Repo.one()` (or `limit(1)`); `Repo.one/1` raises `Ecto.MultipleResultsError` on more than one row.

## Preloading Associations

<!-- epg:bad -->
```elixir
images = Repo.all(Image)
# image.folder is %Ecto.Association.NotLoaded{} — and loading it per row is N+1
Enum.map(images, fn image -> image.folder.name end)
```

```elixir
images =
  Image
  |> where(user_id: ^scope.user.id)
  |> preload(:folder)
  |> Repo.all()
```

When you also filter on the association, join and preload from the join in one query: `join(query, :inner, [i], f in assoc(i, :folder)) |> preload([_i, f], folder: f)`.

Join-preload vs separate-query trade-offs, per-parent limits and N+1 detection: see the `ecto-queries-performance` skill.

## Transactions — `Repo.transact/2`

The function must return `{:ok, value}` (commit) or `{:error, reason}` (rollback); `transact` returns that value unchanged, so a plain `with` is the whole pattern.

```elixir
def create_folder_with_images(%Scope{} = scope, attrs, image_ids) do
  Repo.transact(fn ->
    with {:ok, folder} <- create_folder(scope, attrs) do
      {count, _} =
        Image
        |> where([i], i.id in ^image_ids and i.user_id == ^scope.user.id)
        |> Repo.update_all(set: [folder_id: folder.id, updated_at: DateTime.utc_now(:second)])

      {:ok, %{folder: folder, moved: count}}
    end
  end)
end
```

- `{:error, changeset}` from `create_folder/2` falls out of `with` and rolls back — no `Repo.rollback/1` or catch-all `else` needed.
- `update_all` skips changesets and autogenerated timestamps: set `updated_at` yourself, and keep the scope filter in the query.
- Use `Ecto.Multi` when the number of steps depends on input (one step per cart item, etc.) — see the `ecto-nested-associations` skill.

## Upserts

```elixir
# Migration: create unique_index(:tags, [:user_id, :name])
def upsert_tag(%Scope{} = scope, attrs) do
  %Tag{}
  |> Tag.changeset(attrs, scope)
  |> Repo.insert(
    on_conflict: {:replace_all_except, [:id, :inserted_at]},
    conflict_target: [:user_id, :name],
    returning: true
  )
end
```

- `conflict_target` must match a unique index exactly; its columns are never rewritten (`replace_changed: true` is the default).
- `{:replace_all_except, ...}` overwrites every other column with the changeset's values, including fields the caller left unset. To touch only some columns use `{:replace, [:color, :updated_at]}` — never list the conflict-target columns there.
- Without `returning: true` the returned struct holds the values you tried to insert (e.g. a fresh `inserted_at`), not the row in the database.

## Unique Constraints

```elixir
# Migration
create unique_index(:folders, [:user_id, :name])

# Changeset — both: unsafe_validate_unique for live feedback, unique_constraint for the race
|> unsafe_validate_unique([:name, :user_id], MyApp.Repo)
|> unique_constraint(:name, name: :folders_user_id_name_index)
```

**Case-insensitive uniqueness** (emails, usernames): a plain `unique_index` and `unsafe_validate_unique` are case-sensitive, so `Bob@x.com` and `bob@x.com` both get in. Either use a `citext` column (what `phx.gen.auth` does), or a functional index plus downcasing in the changeset:

```elixir
# Option 1 — citext (comparisons, the unique index and unsafe_validate_unique all ignore case)
execute "CREATE EXTENSION IF NOT EXISTS citext", ""
alter table(:accounts) do
  add :email, :citext, null: false
end
create unique_index(:accounts, [:email])

# Option 2 — expression index; downcase in the changeset so unsafe_validate_unique agrees
create unique_index(:accounts, ["(lower(email))"], name: :accounts_lower_email_index)
# |> update_change(:email, &String.downcase/1)
# |> unique_constraint(:email, name: :accounts_lower_email_index)
```

## Migrations

```elixir
defmodule MyApp.Repo.Migrations.CreateImages do
  use Ecto.Migration

  def change do
    create table(:images) do
      add :title, :string, null: false
      add :filename, :string, null: false
      add :original_name, :string
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :folder_id, references(:folders, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:images, [:user_id])
    create index(:images, [:folder_id])
    create unique_index(:images, [:filename])
    create constraint(:images, :byte_size_must_be_positive, check: "byte_size > 0")
  end
end
```

**Irreversible commands in `change/0`** — they migrate fine and raise `Ecto.MigrationError` on rollback:

<!-- epg:bad -->
```elixir
def change do
  alter table(:images) do
    remove :legacy_path
    modify :title, :text
  end

  execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
end
```

```elixir
def change do
  alter table(:images) do
    remove :legacy_path, :string
    modify :title, :text, from: :string
  end

  execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"
end
```

For data backfills or anything without a natural inverse, write `up/0` and `down/0`.

For tables with live traffic (concurrent indexes, `lock_timeout`, `NOT NULL` and foreign keys without long locks, backfills), see the `ecto-migrations-safety` skill.

## Reference

Field types (`:decimal`, `Ecto.Enum`, `{:array, t}`…), validator and constraint cheat sheets, query syntax (joins, aggregates, null ordering), migration operations and soft delete: see the [Ecto reference](reference.md).

`cast_assoc`, nested forms, `Ecto.Multi` and `on_delete` design: see the `ecto-nested-associations` skill. Multiple changesets per schema and conditional validation: see the `ecto-changeset-patterns` skill.

## Testing

When writing tests for Ecto schemas, changesets, or contexts, invoke `elixir-phoenix-guide:testing-essentials` before writing any `_test.exs` file.
