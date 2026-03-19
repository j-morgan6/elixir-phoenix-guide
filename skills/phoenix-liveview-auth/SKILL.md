---
name: phoenix-liveview-auth
description: MANDATORY for ALL LiveView authentication work. Invoke before writing on_mount hooks, auth plugs for LiveViews, or session handling in LiveView modules.
file_patterns:
  - "**/*_live.ex"
  - "**/*_live/*.ex"
  - "**/user_auth.ex"
auto_suggest: true
---

# Phoenix LiveView Authentication

## RULES — Follow these with no exceptions

1. **Always use `on_mount` callbacks for LiveView auth** — never check auth in `mount/3` directly; `on_mount` runs before mount and centralizes auth logic
2. **Use `mount_current_scope/2` to extract scope from session** — never access session tokens manually or parse session data in LiveViews
3. **Handle both `:cont` and `:halt` returns from `on_mount`** — `:halt` must redirect with a flash message, never silently drop the connection
4. **Resolve import conflicts explicitly** — `Phoenix.Controller` and `Phoenix.LiveView` both export `redirect/2` and `put_flash/3`; use `except:` to avoid ambiguity
5. **Use bracket access `assigns[:current_scope]` in templates** — dot access `@current_scope` crashes on nil when user is not authenticated
6. **Test auth redirects by asserting `{:error, {:redirect, %{to: path}}}`** — don't test auth by checking rendered content; verify the redirect tuple from `live/2`
7. **Define `on_mount` hooks once, reference via `live_session` in router** — never duplicate auth logic across LiveView modules

---

## on_mount Authentication Pattern

The standard pattern for LiveView authentication. Define once, use everywhere via `live_session`.

```elixir
defmodule MyAppWeb.UserAuth do
  use MyAppWeb, :verified_routes
  import Phoenix.LiveView
  import Phoenix.Controller, except: [redirect: 2, put_flash: 3]

  # Called by live_session :require_authenticated_user
  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/users/log_in")

      {:halt, socket}
    end
  end

  # Called by live_session :redirect_if_authenticated
  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:halt, redirect(socket, to: ~p"/")}
    else
      {:cont, socket}
    end
  end

  # Called by live_session :mount_current_scope (public pages)
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      if user = find_user_from_session(session) do
        %Scope{user: user}
      end
    end)
  end

  defp find_user_from_session(%{"user_token" => token}) do
    Accounts.get_user_by_session_token(token)
  end

  defp find_user_from_session(_session), do: nil
end
```

---

## Router Integration

Use `live_session` to apply `on_mount` hooks to groups of LiveViews. Each session shares auth requirements.

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  # Public pages — scope is mounted but not required
  live_session :mount_current_scope,
    on_mount: [{MyAppWeb.UserAuth, :mount_current_scope}] do
    scope "/", MyAppWeb do
      pipe_through :browser

      live "/", HomeLive.Index
    end
  end

  # Authenticated pages — redirects to login if not authenticated
  live_session :require_authenticated_user,
    on_mount: [{MyAppWeb.UserAuth, :require_authenticated_user}] do
    scope "/", MyAppWeb do
      pipe_through [:browser, :require_authenticated_user]

      live "/dashboard", DashboardLive.Index
      live "/settings", SettingsLive.Index
    end
  end

  # Guest-only pages — redirects to home if already authenticated
  live_session :redirect_if_authenticated,
    on_mount: [{MyAppWeb.UserAuth, :redirect_if_authenticated}] do
    scope "/", MyAppWeb do
      pipe_through [:browser, :redirect_if_user]

      live "/users/register", UserRegistrationLive
      live "/users/log_in", UserLoginLive
    end
  end
end
```

---

## Import Conflict Resolution

`Phoenix.Controller` and `Phoenix.LiveView` both export `redirect/2` and `put_flash/3`. When you need both in the same module (common in `UserAuth`):

```elixir
# Bad — compile error or wrong function called
import Phoenix.Controller
import Phoenix.LiveView

# Good — explicitly exclude conflicting functions
import Phoenix.LiveView
import Phoenix.Controller, except: [redirect: 2, put_flash: 3]

# Now redirect/2 and put_flash/3 come from Phoenix.LiveView
```

---

## current_scope vs current_user

Phoenix 1.8+ uses `Scope` structs instead of raw `current_user`. The scope wraps the user and can carry additional context.

```elixir
# Phoenix 1.8+ pattern — Scope struct
defmodule MyApp.Scope do
  defstruct [:user]
end

# In LiveView — access user through scope
def mount(_params, _session, socket) do
  user = socket.assigns.current_scope.user
  {:ok, assign(socket, :posts, Posts.list_posts(user))}
end

# In templates — use bracket access for safety
<%= if assigns[:current_scope] && @current_scope.user do %>
  <p>Welcome, <%= @current_scope.user.email %></p>
<% end %>
```

---

## Safe Template Access

Always use bracket access for assigns that may not exist (e.g., on public pages where auth is optional):

```elixir
# Bad — crashes if current_scope is nil
<%= @current_scope.user.email %>

# Good — safe bracket access
<%= if assigns[:current_scope] && @current_scope.user do %>
  <%= @current_scope.user.email %>
<% end %>

# Also good — assign_new with default
def on_mount(:mount_current_scope, _params, session, socket) do
  {:cont, mount_current_scope(socket, session)}
end
```

---

## Testing LiveView Auth

### Testing Protected Routes

```elixir
describe "require_authenticated_user" do
  test "redirects if not logged in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/dashboard")
  end

  test "renders page when authenticated", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")
    assert html =~ "Dashboard"
  end
end

describe "redirect_if_authenticated" do
  test "redirects if already logged in", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/users/log_in")
  end
end
```

### Testing on_mount Directly

```elixir
describe "on_mount: :require_authenticated_user" do
  test "authenticates user from session", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    assert {:cont, updated_socket} =
             UserAuth.on_mount(
               :require_authenticated_user,
               %{},
               %{"user_token" => token},
               %LiveView.Socket{
                 endpoint: MyAppWeb.Endpoint,
                 assigns: %{__changed__: %{}}
               }
             )

    assert updated_socket.assigns.current_scope.user.id == user.id
  end

  test "redirects when no session token" do
    assert {:halt, updated_socket} =
             UserAuth.on_mount(
               :require_authenticated_user,
               %{},
               %{},
               %LiveView.Socket{
                 endpoint: MyAppWeb.Endpoint,
                 assigns: %{__changed__: %{}, flash: %{}}
               }
             )

    assert updated_socket.redirected == {:redirect, %{to: "/users/log_in"}}
  end
end
```

---

See `testing-essentials` skill for comprehensive testing patterns.
See `phoenix-authorization-patterns` skill for authorization after authentication.
