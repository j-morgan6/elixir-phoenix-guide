# Ecto Reference

> Verified against Elixir 1.20, Ecto 3.14, ecto_sql 3.14 (PostgreSQL) — October 2026

Cheat sheets for the `ecto-essentials` skill. Examples use its `Image` schema (images in folders).

## Field Types

| Type | Postgres | Use for |
|---|---|---|
| `:string` | `varchar(255)` | Short text (titles, names) |
| `:string` in schema, `:text` in migration | `text` | Long text — the schema type stays `:string` |
| `:integer` | `integer` / `bigint` | Counts, sizes |
| `:float` | `double precision` | Measurements where rounding error is acceptable — **never money** |
| `:decimal` | `numeric` | Money and exact values (returns `Decimal` structs — compare with `Decimal.compare/2`, not `==`) |
| `:boolean` | `boolean` | Flags |
| `:date`, `:time` | `date`, `time` | Calendar dates, wall-clock times |
| `:utc_datetime` | `timestamp(0)` | Timestamps to the second — the Phoenix 1.8 default |
| `:utc_datetime_usec` | `timestamp` | Timestamps where ordering within a second matters |
| `:naive_datetime` | `timestamp(0)` | Avoid — no timezone; the pre-1.8 `timestamps()` default |
| `:binary` | `bytea` | Raw bytes (tokens, hashes) |
| `:binary_id` | `uuid` | UUID keys: `@primary_key {:id, :binary_id, autogenerate: true}` plus `@foreign_key_type :binary_id` |
| `:map` | `jsonb` | Free-form JSON (keys come back as strings) |
| `{:array, :string}` | `varchar[]` | Tags, small lists of scalars |
| `Ecto.Enum` | `varchar` (or a Postgres enum) | Closed sets: `field :status, Ecto.Enum, values: [:draft, :published]` |

`citext` (case-insensitive text) is a migration type: `add :email, :citext` after `execute "CREATE EXTENSION IF NOT EXISTS citext", ""`. The schema field stays `:string`.

## Associations

```elixir
belongs_to :folder, MyApp.Media.Folder          # owns the folder_id column
has_many :images, MyApp.Media.Image             # images.folder_id points here
has_one :profile, MyApp.Accounts.Profile
many_to_many :tags, MyApp.Media.Tag, join_through: "images_tags", on_replace: :delete
has_many :comments_on_images, through: [:images, :comments]
```

## Validators

```elixir
changeset
|> validate_required([:title, :body])
|> validate_length(:title, min: 1, max: 255)
|> validate_length(:password, max: 72, count: :bytes)
|> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
|> validate_inclusion(:content_type, ~w(image/jpeg image/png))
|> validate_exclusion(:username, ~w(admin root))
|> validate_number(:price, greater_than_or_equal_to: 0)
|> validate_confirmation(:password, message: "does not match password")
|> validate_acceptance(:terms_of_service)
|> validate_change(:url, fn :url, url ->
  if String.starts_with?(url, "https://"), do: [], else: [url: "must use https"]
end)
```

## Constraint Functions

Each needs the matching database object; without it the error raises instead of landing in the changeset.

```elixir
changeset
|> unique_constraint(:email)                                    # unique_index(:users, [:email])
|> unique_constraint(:name, name: :folders_user_id_name_index)  # composite or custom-named index
|> foreign_key_constraint(:folder_id)                           # references(:folders)
|> check_constraint(:price, name: :price_must_be_positive)      # create constraint(...)
|> no_assoc_constraint(:images)                                 # on delete: block if children exist
```

`no_assoc_constraint/3` goes on the parent's delete changeset and pairs with `on_delete: :restrict` (or `:nothing`) on the child's reference:

```elixir
folder
|> Ecto.Changeset.change()
|> Ecto.Changeset.no_assoc_constraint(:images)
|> Repo.delete()
```

## Changeset Actions

Errors only render once the changeset has an action. In LiveView, `to_form(changeset, action: :validate)` sets it so errors show while typing. Outside a Repo call, `Ecto.Changeset.apply_action(changeset, :insert)` returns `{:ok, struct}` or `{:error, changeset}` with the action set.

## Query Syntax

```elixir
import Ecto.Query

# Keyword syntax and pipe syntax are equivalent
from i in Image, where: i.user_id == ^user_id and i.byte_size > 1000, order_by: [desc: i.inserted_at]

Image
|> where([i], i.user_id == ^user_id)
|> order_by([i], desc: i.inserted_at, desc: i.id)
|> limit(20)

# One row from a query that may match many — Repo.one/1 alone raises MultipleResultsError
query |> first(:inserted_at) |> Repo.one()

# Select a map or a subset
from i in Image, select: %{id: i.id, title: i.title}

# Joins
from i in Image, join: f in assoc(i, :folder), where: f.name == ^name
from i in Image, left_join: f in assoc(i, :folder), select: {i, f}

# Preloads: nested, and with a custom query
from f in Folder, preload: [images: :tags]
recent = from i in Image, order_by: [desc: i.inserted_at], limit: 5
from f in Folder, preload: [images: ^recent]

# Aggregates
Repo.aggregate(Image, :count)
Repo.aggregate(from(i in Image, where: i.user_id == ^user_id), :sum, :byte_size)
from(i in Image, group_by: i.folder_id, select: {i.folder_id, count(i.id)}) |> Repo.all() |> Map.new()

# NULL ordering
from i in Image, order_by: [asc_nulls_last: i.folder_id]
from i in Image, order_by: [desc_nulls_first: i.priority]

# Exists / fetch by several fields
Repo.exists?(from i in Image, where: i.folder_id == ^folder_id)
Repo.all_by(Image, folder_id: folder_id, user_id: user_id)
```

Preloading a custom query with `limit` limits across **all** parents, not per parent. For "latest N per parent" use a lateral join or a window function.

## Repo Return Shapes

| Call | Returns |
|---|---|
| `get/2`, `get_by/2`, `one/1` | struct or `nil` (`one` raises on >1 row) |
| `get!/2`, `get_by!/2`, `one!/1` | struct or raises `Ecto.NoResultsError` |
| `insert/2`, `update/2`, `delete/2` | `{:ok, struct}` or `{:error, changeset}` |
| `insert!/2`, `update!/2`, `delete!/2` | struct or raises `Ecto.InvalidChangesetError` |
| `insert_all/3`, `update_all/3`, `delete_all/2` | `{count, nil \| returned_rows}` — no changesets, no timestamps, constraint violations raise |
| `transact/2` | whatever the function returned: `{:ok, _}` or `{:error, _}` |

## Migration Operations

All of these are reversible inside `change/0`:

```elixir
alter table(:images) do
  add :priority, :integer, default: 0, null: false
  remove :legacy_path, :string
  modify :title, :text, from: :string
end

rename table(:images), :name, to: :title
rename table(:pictures), to: table(:images)

create index(:images, [:title])
create unique_index(:folders, [:user_id, :name])
create index(:images, [:user_id], where: "deleted_at IS NULL", name: :images_live_user_id_index)
drop index(:images, [:title])

create constraint(:images, :byte_size_must_be_positive, check: "byte_size > 0")

execute "CREATE EXTENSION IF NOT EXISTS citext", ""
```

Not reversible in `change/0`: `remove/1` (no type), `modify/3` without `from:`, `execute/1`, `remove_if_exists`, `drop table(...)`, `drop constraint(...)`. Use the forms above or write `up/0` and `down/0`.

Generate with `mix ecto.gen.migration create_images`; never edit a migration that has already run in another environment — add a new one.

## Soft Delete

`deleted_at` is a privileged field: don't `cast` it. Set it directly.

```elixir
# Schema
field :deleted_at, :utc_datetime

# Context: every read filters it, e.g. list_images/2
def list_images(%Scope{} = scope, filters \\ []) do
  Image
  |> where([i], i.user_id == ^scope.user.id and is_nil(i.deleted_at))
  |> filter_images(filters)
  |> Repo.all()
end

def soft_delete_image(%Scope{} = scope, %Image{} = image) do
  true = image.user_id == scope.user.id

  image
  |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
  |> Repo.update()
end
```

<!-- epg:bad -->
```elixir
# Silently does nothing: Image.changeset/3 doesn't cast :deleted_at
def soft_delete_image(scope, image), do: update_image(scope, image, %{deleted_at: DateTime.utc_now()})
```

Every read path must filter `is_nil(deleted_at)`, and unique indexes need `where: "deleted_at IS NULL"` so a deleted row doesn't block re-creating the same name.
