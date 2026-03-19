---
name: phoenix-auth-customization
description: MANDATORY when extending phx.gen.auth with custom fields. Invoke before adding usernames, profiles, or custom registration fields.
file_patterns:
  - "**/accounts.ex"
  - "**/accounts/*.ex"
  - "**/user.ex"
  - "**/user_registration_live.ex"
auto_suggest: true
---

# Phoenix Auth Customization

## RULES — Follow these with no exceptions

1. **Never modify generated auth migrations** — create separate migrations for custom fields; generated migrations are tested and correct
2. **Update `registration_changeset` to cast and validate new fields** — don't create a separate changeset for initial registration
3. **Update test fixtures when adding required fields** — missing fixture fields cause cryptic test failures across the entire test suite
4. **Confirm users in test fixtures for password-based auth** — set `confirmed_at: DateTime.utc_now(:second)` or tests requiring authenticated users will fail
5. **Update both the registration form AND the `save/2` handler** — the form must send the field, and the handler must pass it to the context
6. **Use `unique_constraint` + database unique index for uniqueness** — never validate uniqueness in application code alone

---

## Running phx.gen.auth

Start with the generator, then extend. Never hand-roll auth.

```bash
# Generate auth with LiveView (recommended)
mix phx.gen.auth Accounts User users

# This creates:
# - Migration: priv/repo/migrations/*_create_users_auth_tables.exs
# - Schema: lib/my_app/accounts/user.ex
# - Context: lib/my_app/accounts.ex
# - LiveViews: lib/my_app_web/live/user_*_live.ex
# - Components: lib/my_app_web/controllers/user_session_controller.ex
# - Plugs: lib/my_app_web/user_auth.ex
# - Tests: test/my_app/accounts_test.exs, test/my_app_web/live/user_*_live_test.exs
```

---

## Adding Custom Fields

### Step 1: Create a Separate Migration

```bash
mix ecto.gen.migration add_username_to_users
```

```elixir
defmodule MyApp.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :username, :string, null: false
    end

    create unique_index(:users, [:username])
  end
end
```

### Step 2: Update the Schema

```elixir
defmodule MyApp.Accounts.User do
  schema "users" do
    field :email, :string
    field :username, :string  # Add new field
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime

    timestamps()
  end

  # Update registration_changeset to include username
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :username, :password])
    |> validate_required([:username])
    |> validate_username()
    |> validate_email(opts)
    |> validate_password(opts)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "only letters, numbers, and underscores"
    )
    |> validate_length(:username, min: 3, max: 30)
    |> unsafe_validate_unique(:username, MyApp.Repo)
    |> unique_constraint(:username)
  end
end
```

### Step 3: Update the Registration LiveView

```elixir
# In user_registration_live.ex — update the form
def render(assigns) do
  ~H"""
  <.simple_form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
    <.input field={@form[:email]} type="email" label="Email" required />
    <.input field={@form[:username]} type="text" label="Username" required />
    <.input field={@form[:password]} type="password" label="Password" required />
    <:actions>
      <.button phx-disable-with="Creating account..." class="w-full">
        Create an account
      </.button>
    </:actions>
  </.simple_form>
  """
end

# Update the save handler to pass username
def handle_event("save", %{"user" => user_params}, socket) do
  case Accounts.register_user(user_params) do
    {:ok, user} ->
      # ... existing logic
    {:error, %Ecto.Changeset{} = changeset} ->
      {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end
end
```

---

## Updating Test Fixtures

This is the most commonly missed step. Every test that creates a user will break if fixtures don't include new required fields.

```elixir
defmodule MyApp.AccountsFixtures do
  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def unique_user_username, do: "user#{System.unique_integer([:positive])}"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      username: unique_user_username(),  # Add new required field
      password: "hello world!"
    })
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> MyApp.Accounts.register_user()

    # Confirm user for password-based auth
    {:ok, user} =
      user
      |> Ecto.Changeset.change(%{confirmed_at: DateTime.utc_now(:second)})
      |> MyApp.Repo.update()

    user
  end
end
```

### Why Confirmation Matters

Without `confirmed_at`, the generated auth code treats the user as unconfirmed. Tests that log in users will silently fail or return unexpected redirects.

```elixir
# Bad — user is unconfirmed, login tests may fail
def user_fixture(attrs \\ %{}) do
  {:ok, user} =
    attrs
    |> valid_user_attributes()
    |> MyApp.Accounts.register_user()

  user  # Missing confirmation!
end

# Good — user is confirmed and ready for auth tests
def user_fixture(attrs \\ %{}) do
  {:ok, user} =
    attrs
    |> valid_user_attributes()
    |> MyApp.Accounts.register_user()

  {:ok, user} =
    user
    |> Ecto.Changeset.change(%{confirmed_at: DateTime.utc_now(:second)})
    |> MyApp.Repo.update()

  user
end
```

---

## Adding Profile Fields Later

For non-auth fields (bio, avatar, display name), create a separate `profile_changeset`:

```elixir
# In user.ex
def profile_changeset(user, attrs) do
  user
  |> cast(attrs, [:bio, :display_name, :avatar_url])
  |> validate_length(:bio, max: 500)
  |> validate_length(:display_name, max: 50)
end

# In accounts.ex
def update_user_profile(user, attrs) do
  user
  |> User.profile_changeset(attrs)
  |> Repo.update()
end
```

---

## Testing Auth Customization

```elixir
describe "register_user/1" do
  test "requires username" do
    {:error, changeset} = Accounts.register_user(%{
      email: "test@example.com",
      password: "validpassword123"
    })

    assert "can't be blank" in errors_on(changeset).username
  end

  test "validates username format" do
    {:error, changeset} = Accounts.register_user(%{
      email: "test@example.com",
      username: "has spaces",
      password: "validpassword123"
    })

    assert "only letters, numbers, and underscores" in errors_on(changeset).username
  end

  test "enforces unique username" do
    %{username: username} = user_fixture()

    {:error, changeset} = Accounts.register_user(%{
      email: "other@example.com",
      username: username,
      password: "validpassword123"
    })

    assert "has already been taken" in errors_on(changeset).username
  end
end
```

---

See `ecto-changeset-patterns` skill for advanced changeset composition.
See `phoenix-liveview-auth` skill for on_mount and auth redirect patterns.
See `testing-essentials` skill for comprehensive testing patterns.
