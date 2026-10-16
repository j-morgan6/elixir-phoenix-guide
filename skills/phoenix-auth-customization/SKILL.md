---
name: phoenix-auth-customization
description: "Use when adding fields to the phx.gen.auth user — usernames, profile fields, a registration changeset, migrations and fixtures alongside generated auth. Not for on_mount/live_session (phoenix-liveview-auth) or permissions (phoenix-authorization-patterns)."
---

# Phoenix Auth Customization

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Use the generated auth; extend it, don't rewrite it** — keep `UserAuth`, `UserToken`, the session controller and the generated tests. Add fields and functions next to them; never paste a pre-1.8 `User` module or `UserAuth` over the generated one.
2. **Never edit the generated auth migration** — add a new migration for each new column.
3. **Add a `registration_changeset/3` that pipes `email_changeset/3`** — 1.8 has no registration changeset: `register_user/1` uses `email_changeset/3`, which the settings page also uses to change email. Requiring a new field inside `email_changeset` breaks email changes.
4. **Registration is email-only (magic link)** — don't add a password input to registration. A password set at sign-up is silently dropped by `email_changeset`, and if you make it stick, `login_user_by_magic_link/1` raises for unconfirmed users with a password (see "Mixing magic link and password registration" in `mix help phx.gen.auth`).
5. **Add only the new line to the schema** — keep `field :authenticated_at, :utc_datetime, virtual: true` (sudo mode reads it) and `timestamps(type: :utc_datetime)`.
6. **Use the generated fixtures; add the new field to `valid_user_attributes/1`** — `user_fixture/1` already confirms the user via a magic link; `unconfirmed_user_fixture/1`, `user_scope_fixture/0,1` and `set_password/1` already exist.
7. **Never `cast` privileged fields** — `:role`, `:confirmed_at`, `:org_id`, `:hashed_password` are set with `change/2` / `put_change/3` in a dedicated context function, never from form params.
8. **Uniqueness = unique index + `unique_constraint`** — plus `unsafe_validate_unique` for early feedback, skipped during `phx-change` via the generator's `validate_unique: false` option.
9. **Update every caller of the changed changeset** — the registration LiveView's `mount` and `"validate"` handler, `register_user/1`, and the generated `accounts_test.exs` tests that call `register_user(%{email: ...})` directly.

---

## What phx.gen.auth Generates (1.8)

```bash
mix phx.gen.auth Accounts User users --live      # or --no-live for controllers
```

- `lib/my_app/accounts.ex`, `accounts/user.ex`, `accounts/user_token.ex`, `accounts/user_notifier.ex`, `accounts/scope.ex`
- `lib/my_app_web/user_auth.ex`, `controllers/user_session_controller.ex`
- `--live`: `live/user_live/registration.ex`, `login.ex`, `confirmation.ex`, `settings.ex`; `--no-live`: registration, session and settings controllers + templates
- `test/support/fixtures/accounts_fixtures.ex` and tests for all of the above
- a `config :my_app, :scopes` entry so later `phx.gen.live`/`phx.gen.context` runs generate scoped code (see the `phoenix-scopes-and-generators` skill)

Users register with an email only, receive a magic link, and may set a password later in settings.

---

## Adding a Field (username)

### 1. Migration

```bash
mix ecto.gen.migration add_username_to_users
```

```elixir
defmodule MyApp.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # citext (enabled by the auth migration) makes uniqueness case-insensitive, like email
      add :username, :citext, null: false
    end

    create unique_index(:users, [:username])
  end
end
```

On a table that already has rows, add the column nullable, backfill, then add `NOT NULL` and build the unique index with `concurrently: true` in later migrations (the steps are in the `ecto-migrations-safety` skill).

### 2. Schema — add one line

```elixir
schema "users" do
  # ...generated fields stay as they are
  field :username, :string
end
```

### 3. A registration changeset that builds on email_changeset

```elixir
@doc """
A user changeset for registration. Same options as `email_changeset/3`.
"""
def registration_changeset(user, attrs, opts \\ []) do
  user
  |> email_changeset(attrs, opts)
  |> cast(attrs, [:username])
  |> validate_username(opts)
end

defp validate_username(changeset, opts) do
  changeset =
    changeset
    |> validate_required([:username])
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "only letters, numbers, and underscores"
    )

  if Keyword.get(opts, :validate_unique, true) do
    changeset
    |> unsafe_validate_unique(:username, MyApp.Repo)
    |> unique_constraint(:username)
  else
    changeset
  end
end
```

### 4. Point the context at it

```elixir
# accounts.ex
def register_user(attrs) do
  %User{}
  |> User.registration_changeset(attrs)
  |> Repo.insert()
end

def change_user_registration(%User{} = user, attrs \\ %{}, opts \\ []) do
  User.registration_changeset(user, attrs, opts)
end
```

### 5. Registration LiveView

Swap `change_user_email` for `change_user_registration` in `mount/3` and the `"validate"` handler, and add the input. The `"save"` handler already passes all `user_params` to `register_user/1`.

```elixir
def mount(_params, _session, socket) do
  changeset = Accounts.change_user_registration(%User{}, %{}, validate_unique: false)
  {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
end

def handle_event("validate", %{"user" => user_params}, socket) do
  changeset = Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
  {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
end
```

Keep the generated first `mount/3` clause that redirects already-logged-in users, and keep `@impl true` on the first clause.

```heex
<.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
  <.input field={@form[:email]} type="email" label="Email" autocomplete="username" required />
  <.input field={@form[:username]} type="text" label="Username" required />

  <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
    Create an account
  </.button>
</.form>
```

With `--no-live`, make the same change in `UserRegistrationController.new/2` and `registration_new.html.heex`.

---

## Fixtures and Generated Tests

Only `valid_user_attributes/1` changes:

```elixir
def unique_user_username, do: "user#{System.unique_integer([:positive])}"

def valid_user_attributes(attrs \\ %{}) do
  Enum.into(attrs, %{
    email: unique_user_email(),
    username: unique_user_username()
  })
end
```

Everything else is already there: `user_fixture/1` (confirmed via magic link), `unconfirmed_user_fixture/1`, `user_scope_fixture/0,1`, `set_password/1` (for password-login tests), `register_and_log_in_user/1` in `ConnCase`. Do not add `password:` or `confirmed_at:` to the attributes.

Then fix the generated tests that bypass fixtures — e.g. in `accounts_test.exs`, `register_user(%{email: email})` becomes `register_user(valid_user_attributes(email: email))`. Registration tests that submit `valid_user_attributes/1` keep working; ones that submit a literal `%{"email" => ...}` and expect success need a `"username"`.

```elixir
describe "register_user/1" do
  test "requires username" do
    {:error, changeset} = Accounts.register_user(%{email: unique_user_email()})
    assert "can't be blank" in errors_on(changeset).username
  end

  test "enforces unique username case-insensitively" do
    %{username: username} = user_fixture()

    {:error, changeset} =
      Accounts.register_user(valid_user_attributes(username: String.upcase(username)))

    assert "has already been taken" in errors_on(changeset).username
  end

  test "changing email does not require username" do
    user = user_fixture()
    changeset = Accounts.change_user_email(user, %{email: unique_user_email()})
    assert changeset.valid?
  end
end
```

---

## Profile Fields and Privileged Fields

User-editable fields that aren't part of sign-up get their own changeset and a scope-taking context function, like the generated settings functions:

```elixir
# user.ex
def profile_changeset(user, attrs) do
  user
  |> cast(attrs, [:display_name, :bio])
  |> validate_length(:display_name, max: 50)
  |> validate_length(:bio, max: 500)
end

# accounts.ex
def update_user_profile(%Scope{user: user}, attrs) do
  user
  |> User.profile_changeset(attrs)
  |> Repo.update()
end
```

Privileged fields (a `role`, an org membership) are never in a `cast` list. Add the column with a safe default (`field :role, Ecto.Enum, values: [:member, :admin], default: :member`), set it from an admin-only function with `Ecto.Changeset.change(user, role: :admin)`, and expose it to authorization through the scope — see the `phoenix-authorization-patterns` skill.

---

See the `phoenix-liveview-auth` skill for on_mount hooks, sudo mode and routes.
See the `ecto-changeset-patterns` skill for changeset composition.
See the `testing-essentials` skill for general testing patterns.
