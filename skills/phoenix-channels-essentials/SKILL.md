---
name: phoenix-channels-essentials
description: "Use when building WebSocket features with Phoenix Channels — socket auth and tokens, join authorization, handle_in/push/broadcast, intercept/handle_out, Presence. Not for LiveView updates (use phoenix-pubsub-patterns)."
---

# Phoenix Channels Essentials

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 — October 2026

For non-LiveView real-time features: mobile clients, SPAs, external APIs, inter-service communication.

## RULES — Follow these with no exceptions

1. **Authenticate in `connect/3`; return `:error` otherwise.** Same-origin browser clients can reuse the phx.gen.auth session through `connect_info: [session: @session_options]`; other clients use a `Phoenix.Token` verified with an explicit `max_age` (keep it short, e.g. `86_400`; it can't be revoked).
2. **Make sockets disconnectable on logout.** `id/1` returns a topic you can broadcast `"disconnect"` to. With session auth, return the session's `live_socket_id` and the generated `log_out_user/1` already does it.
3. **Authorize in `join/3` through the scope** — load the topic's resource with `socket.assigns.current_scope` and return `{:error, %{reason: "unauthorized"}}` if that fails. The topic string is client input.
4. **Keep `check_origin` on in production.** Turning it off for a cookie-authenticated socket leaves the CSRF check as the only guard against cross-site WebSocket hijacking; Phoenix raises if both `check_origin` and `check_csrf` are `false`.
5. **Keep channel modules thin** — delegate to context functions that take the scope.
6. **Reply when the client needs the outcome** (`{:reply, {:ok, payload} | {:error, payload}, socket}`). `{:noreply, socket}` is fine for fire-and-forget events (typing indicators, the generator's `"shout"`).
7. **Use `intercept`/`handle_out` only to filter or customize a broadcast per subscriber.** An intercepted event is encoded once per subscriber instead of once per topic.
8. **Use `Phoenix.Presence` for who's online**, in channels and LiveViews. In channel tests, `assert_push "presence_state", _` before you read `Presence.list/1`.

---

## Endpoint Configuration

```elixir
# lib/my_app_web/endpoint.ex
socket "/socket", MyAppWeb.UserSocket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: false
```

`@session_options` is the attribute the generated endpoint already defines for `/live`. `check_origin` defaults to `true` (the request's `origin` must match the endpoint's `url: [host: ...]`); generated `dev.exs` turns it off. If you serve several hosts, list them in prod config:

```elixir
# config/runtime.exs
config :my_app, MyAppWeb.Endpoint,
  check_origin: ["https://example.com", "https://www.example.com"]
```

Native mobile clients don't send `origin`, so the check doesn't apply to them; they must use token auth.

---

## Socket Authentication

### Browser clients: reuse the session (revocable)

```elixir
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket

  alias MyApp.Accounts
  alias MyApp.Accounts.Scope

  channel "room:*", MyAppWeb.RoomChannel

  @impl true
  def connect(_params, socket, %{session: %{"user_token" => token} = session}) do
    case Accounts.get_user_by_session_token(token) do
      {user, _token_inserted_at} ->
        {:ok,
         socket
         |> assign(:current_scope, Scope.for_user(user))
         |> assign(:live_socket_id, session["live_socket_id"])}

      nil ->
        :error
    end
  end

  # No session cookie, failed CSRF check (session is nil), or a guest.
  def connect(_params, _socket, _connect_info), do: :error

  # Same id as the LiveView socket: UserAuth.log_out_user/1 broadcasts
  # "disconnect" to it, and the deleted session token blocks the reconnect.
  @impl true
  def id(socket), do: socket.assigns.live_socket_id
end
```

```javascript
// assets/js/user_socket.js: the session is only read if _csrf_token is sent
import {Socket} from "phoenix"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const socket = new Socket("/socket", {params: {_csrf_token: csrfToken}})
socket.connect()
export default socket
```

### Other clients: Phoenix.Token

Only sign a token for a logged-in user. A plug in the `:browser` pipeline (after `:fetch_current_scope_for_user`) keeps guests working:

```elixir
# lib/my_app_web/user_auth.ex
def put_socket_token(conn, _opts) do
  case conn.assigns[:current_scope] do
    %{user: %{id: user_id}} ->
      assign(conn, :socket_token, Phoenix.Token.sign(conn, "user socket", user_id))

    _guest ->
      assign(conn, :socket_token, nil)
  end
end
```

```heex
<%!-- root.html.heex, in <head> --%>
<meta :if={@socket_token} name="socket-token" content={@socket_token} />
```

```javascript
const token = document.querySelector("meta[name='socket-token']")?.content
if (token) {
  const socket = new Socket("/socket", {authToken: token})
  socket.connect()
}
```

```elixir
# endpoint.ex: auth_token: true sends the token in a header, not the URL
socket "/socket", MyAppWeb.UserSocket, websocket: true, longpoll: false, auth_token: true

# user_socket.ex
@impl true
def connect(_params, socket, %{auth_token: token}) when is_binary(token) do
  # Always pass max_age (1 day here). Don't extend it: the token can't be revoked.
  with {:ok, user_id} <- Phoenix.Token.verify(socket, "user socket", token, max_age: 86_400),
       %User{} = user <- Accounts.get_user(user_id) do
    {:ok, assign(socket, :current_scope, Scope.for_user(user))}
  else
    _ -> :error
  end
end

def connect(_params, _socket, _connect_info), do: :error

@impl true
def id(socket), do: "user_socket:#{socket.assigns.current_scope.user.id}"
```

`Accounts.get_user/1` is `Repo.get(User, id)`, which you add; the generator only has `get_user!/1`. A mobile client sends the token from your API login response instead of a meta tag.

On logout, close that user's open sockets. Add this to the generated `log_out_user/1` before the session is renewed:

```elixir
# assigns[...]: the generated UserAuth tests call log_out_user/1 without it
if scope = conn.assigns[:current_scope] do
  MyAppWeb.Endpoint.broadcast("user_socket:#{scope.user.id}", "disconnect", %{})
end
```

This closes the user's sockets on every device; clients still holding a valid token reconnect. A token copied before logout stays valid until `max_age`, so use session auth when you need real revocation.

<!-- epg:bad -->
```elixir
# No authentication: anyone can connect and join
def connect(_params, socket, _connect_info), do: {:ok, socket}
```

---

## Topic Authorization

```elixir
defmodule MyAppWeb.RoomChannel do
  use MyAppWeb, :channel

  alias MyApp.Chat

  @impl true
  def join("room:" <> room_id, _payload, socket) do
    # fetch_room/2 scopes the lookup and returns {:error, :not_found} for
    # rooms the user can't see, including a non-numeric id.
    case Chat.fetch_room(socket.assigns.current_scope, room_id) do
      {:ok, room} -> {:ok, assign(socket, :room, room)}
      {:error, :not_found} -> {:error, %{reason: "unauthorized"}}
    end
  end
end
```

<!-- epg:bad -->
```elixir
# Any authenticated user can join any room
def join("room:" <> room_id, _payload, socket) do
  {:ok, assign(socket, :room_id, room_id)}
end
```

---

## Message Patterns

### handle_in: reply when the client needs the outcome

```elixir
@impl true
def handle_in("new_msg", %{"body" => body}, socket) do
  %{current_scope: scope, room: room} = socket.assigns

  case Chat.create_message(scope, room, %{"body" => body}) do
    {:ok, message} ->
      broadcast!(socket, "new_msg", %{id: message.id, body: message.body, user_id: message.user_id})
      {:reply, :ok, socket}

    {:error, changeset} ->
      errors = Ecto.Changeset.traverse_errors(changeset, &MyAppWeb.CoreComponents.translate_error/1)
      {:reply, {:error, %{errors: errors}}, socket}
  end
end

# Fire-and-forget: nobody waits for a result
def handle_in("typing", _payload, socket) do
  broadcast_from!(socket, "typing", %{user_id: socket.assigns.current_scope.user.id})
  {:noreply, socket}
end
```

Push explicit maps. A broadcast payload goes to every subscriber as-is, so never broadcast whole Ecto structs (hidden fields, unloaded associations).

| Call | Goes to |
|---|---|
| `push(socket, event, payload)` | this client only |
| `broadcast!(socket, event, payload)` | everyone on the topic, including the sender |
| `broadcast_from!(socket, event, payload)` | everyone except the sender |
| `MyAppWeb.Endpoint.broadcast(topic, event, payload)` | a topic, from outside a channel (contexts, jobs) |

### intercept / handle_out: per-subscriber filtering

```elixir
intercept ["new_msg"]

@impl true
def handle_out("new_msg", payload, socket) do
  if Chat.blocked?(socket.assigns.current_scope, payload.user_id) do
    {:noreply, socket}
  else
    push(socket, "new_msg", payload)
    {:noreply, socket}
  end
end
```

Declare `intercept` above the `handle_out/3` clauses. Phoenix prints a compile-time warning for a `handle_out/3` event that isn't intercepted yet, and an event that isn't intercepted never reaches `handle_out/3`.

### handle_info: messages from PubSub and other processes

```elixir
@impl true
def handle_info({:new_notification, notification}, socket) do
  push(socket, "notification", %{title: notification.title, body: notification.body})
  {:noreply, socket}
end
```

---

## Presence

Generate it with `mix phx.gen.presence`, then add `MyAppWeb.Presence` to the supervision tree after `{Phoenix.PubSub, ...}` and before the endpoint.

### In a channel

```elixir
@impl true
def join("room:" <> room_id, _payload, socket) do
  case Chat.fetch_room(socket.assigns.current_scope, room_id) do
    {:ok, room} ->
      send(self(), :after_join)
      {:ok, assign(socket, :room, room)}

    {:error, :not_found} ->
      {:error, %{reason: "unauthorized"}}
  end
end

@impl true
def handle_info(:after_join, socket) do
  {:ok, _} =
    MyAppWeb.Presence.track(socket, to_string(socket.assigns.current_scope.user.id), %{
      online_at: System.system_time(:second),
      typing: false
    })

  push(socket, "presence_state", MyAppWeb.Presence.list(socket))
  {:noreply, socket}
end
```

Clients then receive `"presence_diff"` events automatically. Update metadata with `MyAppWeb.Presence.update(socket, key, fn meta -> %{meta | typing: true} end)`.

### In a LiveView

See the `phoenix-pubsub-patterns` skill: the LiveView tracks itself and handles `presence_diff` broadcasts in `handle_info/2`.

---

## Channels vs LiveView vs PubSub

| | Channels | LiveView | PubSub |
|---|---|---|---|
| Client | Any (mobile, SPA, IoT) | Browser | Server processes only |
| Rendering | Client | Server | None |
| Use when | Non-browser clients, custom protocols | Browser UI with real-time updates | Process-to-process events |

---

## Testing Channels

```elixir
defmodule MyAppWeb.RoomChannelTest do
  use MyAppWeb.ChannelCase

  import MyApp.AccountsFixtures
  import MyApp.ChatFixtures

  setup do
    scope = user_scope_fixture()
    room = room_fixture(scope)
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "user socket", scope.user.id)

    {:ok, socket} = connect(MyAppWeb.UserSocket, %{}, connect_info: %{auth_token: token})
    {:ok, _reply, socket} = subscribe_and_join(socket, "room:#{room.id}", %{})

    %{socket: socket, scope: scope, room: room}
  end

  test "new_msg replies ok and broadcasts", %{socket: socket} do
    ref = push(socket, "new_msg", %{"body" => "hello"})

    assert_reply ref, :ok
    assert_broadcast "new_msg", %{body: "hello"}
  end

  test "new_msg with invalid data replies with errors", %{socket: socket} do
    ref = push(socket, "new_msg", %{"body" => ""})

    assert_reply ref, :error, %{errors: %{body: _}}
  end

  test "a non-member cannot join", %{room: room} do
    other = user_scope_fixture()
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "user socket", other.user.id)
    {:ok, socket} = connect(MyAppWeb.UserSocket, %{}, connect_info: %{auth_token: token})

    assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "room:#{room.id}", %{})
  end

  test "connect without a token is refused" do
    assert :error = connect(MyAppWeb.UserSocket, %{})
  end

  test "presence is tracked after join", %{socket: socket, scope: scope} do
    # :after_join runs after join returns; wait for its push before reading.
    assert_push "presence_state", _
    user_id = to_string(scope.user.id)

    assert %{^user_id => %{metas: [%{online_at: _}]}} = MyAppWeb.Presence.list(socket)
  end
end
```

The tests use the token socket. For a session-auth socket, pass the session through `connect_info: %{session: %{"user_token" => token, "live_socket_id" => "users_sessions:test"}}`, with the token from `MyApp.Accounts.generate_user_session_token(user)`.

---

See the `phoenix-pubsub-patterns` skill for server-side PubSub, the `phoenix-liveview-essentials` skill for LiveView real-time patterns, and the `testing-essentials` skill before writing any `_test.exs` file.
