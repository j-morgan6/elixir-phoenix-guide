---
name: phoenix-liveview-auth
description: "Use when protecting LiveViews with the generated phx.gen.auth code — on_mount hooks, live_session, mount_current_scope, sudo mode, logout disconnects, auth tests. Not for extra user fields (phoenix-auth-customization) or per-record permissions (phoenix-authorization-patterns)."
---

# Phoenix LiveView Authentication

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Use the generated `UserAuth`; don't rewrite it** — `mix phx.gen.auth` already ships the plugs, `on_mount` hooks, token reissue, remember-me and socket disconnects. Add routes to its `live_session` blocks; don't re-type `mount_current_scope` or paste pre-1.8 snippets over it.
2. **Use the generated names exactly** — `on_mount` hooks are `:mount_current_scope`, `:require_authenticated` and `:require_sudo_mode`; the router's `live_session`s are `:current_user` and `:require_authenticated_user`; the plug is `:require_authenticated_user`. There is no `:require_authenticated_user` hook and no `:redirect_if_authenticated` hook.
3. **Put login-only LiveViews inside the existing `live_session :require_authenticated_user`** — its scope pipes through the `:require_authenticated_user` plug (HTTP render) *and* runs the `:require_authenticated` hook (websocket mount and live navigation). A `live_session` name may be defined only once in the router. Create a separate one only when its LiveViews need extra `on_mount` hooks (see below).
4. **For guests `@current_scope` is `nil`** — `Scope.for_user(nil)` returns `nil`, not an empty scope. Guard with `@current_scope && @current_scope.user` (or `:if={@current_scope}`).
5. **Never make `/users/log-in` guest-only** — logged-in users are sent there by sudo mode to re-authenticate, so a guest-only guard locks them out of settings. The generator mounts it under `live_session :current_user`; registration redirects logged-in users from its own `mount/3`.
6. **Gate sensitive pages with `:require_sudo_mode`** — `on_mount {MyAppWeb.UserAuth, :require_sudo_mode}` in the LiveView (inside the authenticated `live_session`; it dereferences `current_scope.user`), and re-check `Accounts.sudo_mode?/2` in the action that changes credentials.
7. **Disconnect live sockets when sessions die** — `log_out_user/1` broadcasts `"disconnect"` to the session's `live_socket_id`; after any `Accounts` call that returns expired tokens, call `UserAuth.disconnect_sessions(tokens)`. Never drop `:live_socket_id` from the session.
8. **`get_user_by_session_token/1` returns `{user, token_inserted_at}` or `nil`** — destructure the tuple; never wrap it in a scope directly.
9. **In `on_mount` hooks, fully qualify `Phoenix.LiveView.redirect/2` and `Phoenix.LiveView.put_flash/3`** — `UserAuth` imports `Phoenix.Controller` for its plugs; excluding those imports breaks the plug half.
10. **Test with the generated helpers** — `setup :register_and_log_in_user`, `log_in_user(conn, user, token_authenticated_at: ...)`, and assert `{:error, {:redirect, %{to: path, flash: flash}}}` from `live/2`.

---

## What the Generator Gives You

`mix phx.gen.auth Accounts User users --live` (Phoenix 1.8):

| Piece | Name | Used for |
|---|---|---|
| Plug (in `:browser`) | `:fetch_current_scope_for_user` | assigns `:current_scope` on every request (`nil` for guests) |
| Plug | `:require_authenticated_user` | redirects to `~p"/users/log-in"`, stores `:user_return_to` |
| `on_mount` | `:mount_current_scope` | assigns `:current_scope` on the socket |
| `on_mount` | `:require_authenticated` | halts with redirect to log-in when no user |
| `on_mount` | `:require_sudo_mode` | halts unless the user authenticated in the last 10 minutes |
| `live_session` | `:current_user` | register, log-in, magic-link confirmation (optional auth) |
| `live_session` | `:require_authenticated_user` | settings (login required) |
| Function | `disconnect_sessions/1` | broadcasts `"disconnect"` for a list of `%UserToken{}` |

With `--no-live` there are no `on_mount` hooks, `live_session`s, `live_socket_id` or `disconnect_sessions/1`; instead you get a `require_sudo_mode/2` plug and a `redirect_if_user_is_authenticated/2` plug, used only for `/users/register`.

---

## Adding Your Routes

Add to the generated blocks. Don't create a parallel `live_session` that replaces the generated hooks.

```elixir
scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :require_authenticated_user,
    on_mount: [{MyAppWeb.UserAuth, :require_authenticated}] do
    live "/users/settings", UserLive.Settings, :edit
    live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

    # your login-only LiveViews
    live "/posts", PostLive.Index, :index
    live "/posts/new", PostLive.Form, :new
  end

  post "/users/update-password", UserSessionController, :update_password
end

scope "/", MyAppWeb do
  pipe_through [:browser]

  live_session :current_user,
    on_mount: [{MyAppWeb.UserAuth, :mount_current_scope}] do
    live "/users/register", UserLive.Registration, :new
    live "/users/log-in", UserLive.Login, :new
    live "/users/log-in/:token", UserLive.Confirmation, :new

    # your pages that work with or without a user. (The generated
    # `get "/", PageController, :home` already owns "/": replace it to make "/" a LiveView.)
    live "/explore", ExploreLive, :index
  end

  post "/users/log-in", UserSessionController, :create
  delete "/users/log-out", UserSessionController, :delete
end
```

Need an extra check (admin, org membership) for a group of LiveViews? Give them their own `live_session` whose hook list **starts with** `{MyAppWeb.UserAuth, :require_authenticated}` (so the scope is assigned and checked first), and put it in a `scope` that pipes through `[:browser, :require_authenticated_user]`: `live_session :admin, on_mount: [{MyAppWeb.UserAuth, :require_authenticated}, {MyAppWeb.AdminHooks, :require_admin}]`. For a single LiveView, a module-level `on_mount` inside the existing session works too. See the `phoenix-authorization-patterns` skill.

---

## The Generated Hooks (for reading, not retyping)

This is what `user_auth.ex` contains. If yours differs, you are looking at pre-1.8 code. All `on_mount/4` clauses are grouped together.

```elixir
def on_mount(:mount_current_scope, _params, session, socket) do
  {:cont, mount_current_scope(socket, session)}
end

def on_mount(:require_authenticated, _params, session, socket) do
  socket = mount_current_scope(socket, session)

  if socket.assigns.current_scope && socket.assigns.current_scope.user do
    {:cont, socket}
  else
    socket =
      socket
      |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
      |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

    {:halt, socket}
  end
end

def on_mount(:require_sudo_mode, _params, session, socket) do
  socket = mount_current_scope(socket, session)

  if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
    {:cont, socket}
  else
    socket =
      socket
      |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
      |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

    {:halt, socket}
  end
end

defp mount_current_scope(socket, session) do
  Phoenix.Component.assign_new(socket, :current_scope, fn ->
    {user, _} =
      if user_token = session["user_token"] do
        Accounts.get_user_by_session_token(user_token)
      end || {nil, nil}

    Scope.for_user(user)
  end)
end
```

`assign_new/3` reuses the scope the plug already assigned during the HTTP render, so the token is looked up once per mount phase. `sudo_mode?` reads `user.authenticated_at`, a virtual field the session-token query fills from the token row.

---

## Sudo Mode

Changing email or password requires a recent login. The generated settings LiveView adds the hook at module level, which runs after the `live_session` hooks:

```elixir
defmodule MyAppWeb.UserLive.Settings do
  use MyAppWeb, :live_view

  on_mount {MyAppWeb.UserAuth, :require_sudo_mode}

  # ...
end
```

The redirect goes to `/users/log-in`, which shows a "reauthenticate" variant (email field read-only) when `@current_scope` is set. Use the same hook for your own sensitive pages (delete account, API keys, billing). Since the hook only runs on mount, re-check in the action itself — the generated `update_password` controller action does `true = Accounts.sudo_mode?(user)`.

---

## Magic Links, Logout and Socket Disconnects

- Registration is email-only; `Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))` emails a magic link (valid 15 minutes). `/users/log-in/:token` (`UserLive.Confirmation`) submits to `UserSessionController.create`, which calls `Accounts.login_user_by_magic_link/1`.
- The first magic-link login confirms the user and expires **all** their tokens; `login_user_by_magic_link/1` returns `{:ok, {user, expired_tokens}}` and the controller calls `UserAuth.disconnect_sessions(expired_tokens)`. `update_user_password/2` does the same.
- `log_out_user/1` deletes the session token and broadcasts `"disconnect"` to `live_socket_id` (`"users_sessions:" <> encoded token`), so every open LiveView on that session (other tabs too) drops and re-runs its `on_mount` hooks without a valid token.

Follow the same pattern for anything new that invalidates tokens (account deletion, "log out everywhere"): return the expired `%UserToken{}` list from the context and pass it to `disconnect_sessions/1` in the web layer.

---

## @current_scope in Templates

```heex
<%!-- Guests: @current_scope is nil, so check it before .user --%>
<p :if={@current_scope}>Signed in as {@current_scope.user.email}</p>
<.link :if={!@current_scope} navigate={~p"/users/log-in"}>Log in</.link>
```

Every generated LiveView passes it to the layout: `<Layouts.app flash={@flash} current_scope={@current_scope}>`. Use bracket access `assigns[:current_scope]` only in a component that may render where no auth hook ran (the assign is then absent, not `nil`).

Context calls take the scope, never the user: `Blog.list_posts(socket.assigns.current_scope)`.

---

## Testing LiveView Auth

`ConnCase` (generated) provides `register_and_log_in_user/1` and `log_in_user/3`.

```elixir
describe "posts index" do
  setup :register_and_log_in_user

  test "renders for a logged-in user", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/posts")
    assert has_element?(lv, "h1", "Listing Posts")
  end
end

test "redirects guests to log in", %{conn: conn} do
  assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/posts")
  assert path == ~p"/users/log-in"
  assert %{"error" => "You must log in to access this page."} = flash
end

test "sudo-mode page redirects when the login is stale", %{conn: conn} do
  stale = DateTime.add(DateTime.utc_now(:second), -11, :minute)

  {:ok, conn} =
    conn
    |> log_in_user(user_fixture(), token_authenticated_at: stale)
    |> live(~p"/users/settings")
    |> follow_redirect(conn, ~p"/users/log-in")

  assert conn.resp_body =~ "You must re-authenticate to access this page."
end
```

Calling a hook directly (as the generated `user_auth_test.exs` does):

```elixir
test "require_authenticated halts without a token" do
  socket = %Phoenix.LiveView.Socket{
    endpoint: MyAppWeb.Endpoint,
    assigns: %{__changed__: %{}, flash: %{}}
  }

  assert {:halt, socket} = UserAuth.on_mount(:require_authenticated, %{}, %{}, socket)
  assert socket.assigns.current_scope == nil
end
```

---

See the `phoenix-authorization-patterns` skill for what a logged-in user may do.
See the `phoenix-auth-customization` skill for adding fields to the generated user.
See the `testing-essentials` skill for general LiveView testing patterns.
