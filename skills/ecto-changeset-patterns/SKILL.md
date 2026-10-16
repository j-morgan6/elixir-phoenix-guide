---
name: ecto-changeset-patterns
description: "Use when writing Ecto changeset validations beyond cast/validate_required — custom and cross-field validations (e.g. end date after start date), separate changesets per operation (registration vs update), conditional validation, field transforms, password/email rules, uniqueness checks. Not for parent/child forms or cast_assoc (use ecto-nested-associations)."
---

# Ecto Changeset Patterns

> Verified against Elixir 1.20, Phoenix 1.8, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Create separate named changesets per operation** — `email_changeset`, `password_changeset`, `profile_changeset`; never one `changeset/2` that casts everything
2. **Never `cast` foreign keys or privileged fields** (`:user_id`, `:org_id`, `:role`, `:confirmed_at`, `:deleted_at`) — set them with `put_change`/`change` from trusted code after a scope-checked lookup; for owned records use the Phoenix 1.8 `changeset(struct, attrs, scope)` shape
3. **Compose changesets with pipes** — each validation step is a small private function reused across changesets
4. **Pair `unsafe_validate_unique` with `unique_constraint`** — the first gives live form feedback, the second catches the race; both are case-sensitive unless the column is `citext`
5. **Use `update_change/3` for normalisation** (trim, downcase, slug) — in the changeset, never in the controller or LiveView; call it after `validate_required`
6. **Accept `opts \\ []` to skip expensive steps during live validation** — phx.gen.auth's `validate_unique: false` (no DB query per keystroke) and `hash_password: false` (no Bcrypt per keystroke)
7. **Passwords: `min: 12, max: 72`, plus `max: 72, count: :bytes` before hashing** — Bcrypt only reads the first 72 bytes, and multibyte characters pass a character-count check
8. **Validate in the changeset, not in context functions** — contexts stay thin wrappers around `Repo` calls

---

## Separate Changesets Per Operation

The Phoenix 1.8 `phx.gen.auth` `User` schema already works this way. Here it is with a `role` added:

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :role, Ecto.Enum, values: [:member, :admin], default: :member
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime)
  end

  # Generated. 1.8 registration is email-only (magic link) and register_user/1 uses
  # this changeset; to register extra fields, add a registration_changeset/3 that
  # pipes email_changeset/3 (see the phoenix-auth-customization skill).
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  # Generated
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  # Privileged fields are never in a cast list. Trusted code sets them explicitly.
  # confirm_changeset/1 is generated; role_changeset/2 is yours.
  def confirm_changeset(user), do: change(user, confirmed_at: DateTime.utc_now(:second))

  def role_changeset(user, role) when role in [:member, :admin], do: change(user, role: role)
end
```

User-editable extras (username, profile fields) belong in their own changesets, `registration_changeset/3` and `profile_changeset/2` in the `phoenix-auth-customization` skill. If such a changeset cast `:role` or `:confirmed_at`, any user could promote or confirm themselves by adding a form field. Call `role_changeset/2` only from an admin-only context function.

For records owned by a user, the 1.8 generators take the scope as the third argument and set the owner themselves:

```elixir
def changeset(post, attrs, user_scope) do
  post
  |> cast(attrs, [:title, :body])
  |> validate_required([:title, :body])
  |> put_change(:user_id, user_scope.user.id)
end
```

Mass assignment: anything in a `cast` list can be set from a form or JSON body.

<!-- epg:bad -->
```elixir
# A user can post user_id of another account, or folder_id of someone else's folder
|> cast(attrs, [:title, :folder_id, :user_id])
```

A foreign key the user chooses (`folder_id`) is set from a record loaded through the scope: `folder = get_folder!(scope, folder_id)`, then `put_change(:folder_id, folder.id)` (see `move_image/3` in the `ecto-essentials` skill).

---

## Changeset Composition

The private validators `phx.gen.auth` generates for the changesets above:

```elixir
defp validate_email(changeset, opts) do
  changeset =
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)

  if Keyword.get(opts, :validate_unique, true) do
    changeset
    |> unsafe_validate_unique(:email, MyApp.Repo)
    |> unique_constraint(:email)
    |> validate_email_changed()
  else
    changeset
  end
end

defp validate_email_changed(changeset) do
  if get_field(changeset, :email) && get_change(changeset, :email) == nil do
    add_error(changeset, :email, "did not change")
  else
    changeset
  end
end

defp validate_password(changeset, opts) do
  changeset
  |> validate_required([:password])
  |> validate_length(:password, min: 12, max: 72)
  |> maybe_hash_password(opts)
end

defp maybe_hash_password(changeset, opts) do
  hash_password? = Keyword.get(opts, :hash_password, true)
  password = get_change(changeset, :password)

  if hash_password? && password && changeset.valid? do
    changeset
    # Bcrypt truncates at 72 bytes; "é" is 2 bytes, so 72 characters can exceed it
    |> validate_length(:password, max: 72, count: :bytes)
    |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
    |> delete_change(:password)
  else
    changeset
  end
end
```

phx.gen.auth doesn't downcase emails: its migration makes `email` a `citext` column, so the unique index and `unsafe_validate_unique` already ignore case. **Variant for a plain `text`/`varchar` email column** (not the generator's code): normalise in the changeset and back it with a `lower(email)` unique index (see the `ecto-essentials` skill):

```elixir
changeset
|> validate_required([:email])
|> update_change(:email, &String.downcase/1)
|> unique_constraint(:email, name: :users_lower_email_index)
```

`update_change` after `validate_required` is safe: `validate_required` drops a blank change, so the function never sees `nil`.

---

## Conditional Validation with opts

`opts` exist so the same changeset can run cheaply on every `phx-change` and fully on submit:

```elixir
# Context (generated) — passes opts through
def change_user_password(user, attrs \\ %{}, opts \\ []) do
  User.password_changeset(user, attrs, opts)
end

# Settings LiveView — runs on every keystroke: no Bcrypt
def handle_event("validate_password", %{"user" => user_params}, socket) do
  password_form =
    socket.assigns.current_scope.user
    |> Accounts.change_user_password(user_params, hash_password: false)
    |> to_form(action: :validate)

  {:noreply, assign(socket, password_form: password_form)}
end
```

On submit the context calls `User.password_changeset(user, attrs)` with the defaults, so the password is hashed. Registration works the same way: `change_user_email(%User{}, params, validate_unique: false)` on `phx-change`, the default (uniqueness checked) on insert.

- `hash_password: false` keeps `:password` in the changes (so the form re-renders it) and skips the deliberately slow Bcrypt hash.
- `validate_unique: false` skips `unsafe_validate_unique`'s database query; `unique_constraint` still protects the insert.
- Don't add options that skip validations to make tests faster — use the generated fixtures (see the `testing-essentials` skill).

---

## Field Transformations with update_change

```elixir
def changeset(post, attrs, scope) do
  post
  |> cast(attrs, [:title, :body])
  |> validate_required([:title, :body])
  |> update_change(:title, &String.trim/1)
  |> put_slug()
  |> put_change(:user_id, scope.user.id)
end

defp put_slug(changeset) do
  case get_change(changeset, :title) do
    nil ->
      changeset

    title ->
      slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
      put_change(changeset, :slug, slug)
  end
end
```

---

## Nested Changesets

`cast_assoc`/`cast_embed`, child changesets that must not require the parent's foreign key, and editing child lists from `<.inputs_for>`: see the `ecto-nested-associations` skill.

---

## Testing Changesets

```elixir
describe "email_changeset/3" do
  test "requires email" do
    changeset = User.email_changeset(%User{}, %{})
    assert "can't be blank" in errors_on(changeset).email
  end

  test "rejects an email without @" do
    changeset = User.email_changeset(%User{}, %{email: "nope"}, validate_unique: false)
    assert "must have the @ sign and no spaces" in errors_on(changeset).email
  end
end

describe "password_changeset/3" do
  test "rejects 72 characters that exceed 72 bytes" do
    changeset = User.password_changeset(%User{}, %{password: String.duplicate("é", 72)})
    assert "should be at most 72 byte(s)" in errors_on(changeset).password
  end

  test "keeps the plain password when hash_password: false" do
    changeset = User.password_changeset(%User{}, %{password: "valid password"}, hash_password: false)
    assert get_change(changeset, :password) == "valid password"
    refute get_change(changeset, :hashed_password)
  end
end
```

---

See the `ecto-essentials` skill for schemas, scoped contexts and migrations.
See the `ecto-nested-associations` skill for `cast_assoc` with nested data.
See the `testing-essentials` skill for comprehensive testing patterns.
