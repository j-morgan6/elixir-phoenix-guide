---
name: ecto-changeset-patterns
description: MANDATORY for ALL changeset work beyond basic CRUD. Invoke before writing multiple changesets, cast_assoc, or conditional validation.
file_patterns:
  - "**/*.ex"
auto_suggest: true
---

# Ecto Changeset Patterns

## RULES — Follow these with no exceptions

1. **Create separate named changesets per operation** — `registration_changeset`, `email_changeset`, `password_changeset`; never overload a single `changeset/2`
2. **Never require foreign key fields in `cast_assoc` child changesets** — the parent sets them automatically; requiring them causes "can't be blank" errors
3. **Compose changesets with pipes** — each validation step is a separate function for reuse and clarity
4. **Use `unsafe_validate_unique` paired with `unique_constraint`** — never one without the other; `unsafe_validate_unique` gives fast UI feedback, `unique_constraint` handles race conditions
5. **Use `update_change/3` for field transformations** — trimming, downcasing, slugifying happen in the changeset, never in the controller or context
6. **Accept `opts \\ []` for conditional validation** — allows callers to toggle validation rules without creating yet another changeset function
7. **Validate at the changeset level, not in context functions** — context functions should be thin wrappers around `Repo` calls

---

## Separate Changesets Per Operation

Different operations need different validation rules. Don't overload `changeset/2`.

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :bio, :string

    timestamps()
  end

  # Registration — all fields, password hashing
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :username, :password])
    |> validate_email(opts)
    |> validate_username()
    |> validate_password(opts)
  end

  # Email change — only email, requires reconfirmation
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  # Password change — only password
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_password(opts)
    |> put_password_hash()
  end

  # Profile update — non-sensitive fields only
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :bio])
    |> validate_username()
  end
end
```

---

## cast_assoc — Critical Pitfall

The most common source of "can't be blank" errors. Foreign keys are set automatically by the parent — never require them in the child changeset.

```elixir
# Parent schema
defmodule MyApp.Blog.Post do
  schema "posts" do
    field :title, :string
    has_many :ingredients, MyApp.Blog.Ingredient

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title])
    |> validate_required([:title])
    |> cast_assoc(:ingredients, with: &MyApp.Blog.Ingredient.changeset/2)
  end
end

# Child schema — DO NOT require :post_id
defmodule MyApp.Blog.Ingredient do
  schema "ingredients" do
    field :name, :string
    field :quantity, :string
    belongs_to :post, MyApp.Blog.Post

    timestamps()
  end

  # Bad — :post_id is required but set automatically by cast_assoc
  def changeset(ingredient, attrs) do
    ingredient
    |> cast(attrs, [:name, :quantity, :post_id])
    |> validate_required([:name, :post_id])  # Fails!
  end

  # Good — only require user-provided fields
  def changeset(ingredient, attrs) do
    ingredient
    |> cast(attrs, [:name, :quantity])
    |> validate_required([:name])
  end
end
```

---

## Changeset Composition

Break validation into small, reusable functions. Compose with pipes.

```elixir
defmodule MyApp.Accounts.User do
  # Reusable validation components

  defp validate_email(changeset, opts) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> maybe_validate_unique_email(opts)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/, message: "only letters, numbers, and underscores")
    |> validate_length(:username, min: 3, max: 30)
    |> unsafe_validate_unique(:username, MyApp.Repo)
    |> unique_constraint(:username)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_validate_unique_email(changeset, opts) do
    if Keyword.get(opts, :validate_email, true) do
      changeset
      |> unsafe_validate_unique(:email, MyApp.Repo)
      |> unique_constraint(:email)
    else
      changeset
    end
  end

  defp maybe_hash_password(changeset, opts) do
    if Keyword.get(opts, :hash_password, true) && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(get_change(changeset, :password)))
      |> delete_change(:password)
    else
      changeset
    end
  end
end
```

---

## Conditional Validation with opts

Use `opts` to toggle validation behavior from the caller. This avoids creating a new changeset function for every variation.

```elixir
# In the schema module
def registration_changeset(user, attrs, opts \\ []) do
  user
  |> cast(attrs, [:email, :username, :password])
  |> validate_email(opts)
  |> validate_password(opts)
end

# In the context — normal registration
def register_user(attrs) do
  %User{}
  |> User.registration_changeset(attrs)
  |> Repo.insert()
end

# In tests — skip hashing for speed
def register_user_for_test(attrs) do
  %User{}
  |> User.registration_changeset(attrs, hash_password: false, validate_email: false)
  |> Repo.insert()
end
```

---

## Field Transformations with update_change

Transform field values in the changeset, not in the controller or LiveView.

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :username])
  |> update_change(:email, &String.downcase/1)
  |> update_change(:username, &String.trim/1)
  |> update_change(:username, &String.downcase/1)
end

# For slugs
def changeset(post, attrs) do
  post
  |> cast(attrs, [:title])
  |> validate_required([:title])
  |> generate_slug()
end

defp generate_slug(changeset) do
  case get_change(changeset, :title) do
    nil -> changeset
    title ->
      slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
      put_change(changeset, :slug, slug)
  end
end
```

---

## Uniqueness Validation

Always pair `unsafe_validate_unique` with `unique_constraint`. They serve different purposes.

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :username])
  # Fast check — queries DB, gives immediate UI feedback
  # "unsafe" because another insert could happen between check and insert
  |> unsafe_validate_unique(:email, MyApp.Repo)
  |> unsafe_validate_unique(:username, MyApp.Repo)
  # Constraint check — catches race conditions at insert time
  # Requires a matching unique index in the database
  |> unique_constraint(:email)
  |> unique_constraint(:username)
end
```

---

## Testing Changesets

```elixir
describe "registration_changeset/2" do
  test "valid with all required fields" do
    changeset = User.registration_changeset(%User{}, %{
      email: "test@example.com",
      username: "testuser",
      password: "validpassword123"
    })

    assert changeset.valid?
  end

  test "invalid without email" do
    changeset = User.registration_changeset(%User{}, %{
      username: "testuser",
      password: "validpassword123"
    })

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).email
  end

  test "transforms email to lowercase" do
    changeset = User.email_changeset(%User{}, %{email: "TEST@Example.COM"})
    assert get_change(changeset, :email) == "test@example.com"
  end
end
```

---

See `ecto-essentials` skill for schema and migration patterns.
See `ecto-nested-associations` skill for `cast_assoc` with nested data.
See `testing-essentials` skill for comprehensive testing patterns.
