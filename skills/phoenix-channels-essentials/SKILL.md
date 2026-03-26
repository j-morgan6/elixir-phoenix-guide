---
name: phoenix-channels-essentials
description: MANDATORY for ALL Phoenix Channels work. Invoke before writing socket, channel, or Presence modules.
file_patterns:
  - "**/*_socket.ex"
  - "**/*_channel.ex"
  - "**/channels/**/*.ex"
auto_suggest: true
---

# Phoenix Channels Essentials

For non-LiveView real-time features: mobile clients, SPAs, external APIs, inter-service communication.

## RULES — Follow these with no exceptions

1. **Always authenticate in `connect/3`** — channels bypass the Plug pipeline; tokens must be verified in the socket
2. **Authorize in `join/3`** — verify the user can access the requested topic before allowing the connection
3. **Use `handle_in` for client-to-server, `push` for server-to-client, `broadcast` for server-to-all** — never confuse the direction
4. **Keep channel modules thin** — delegate business logic to context modules; channels are the transport layer
5. **Use Presence for tracking connected users** — don't roll your own presence tracking; Phoenix.Presence handles node distribution
6. **Return `{:reply, :ok, socket}` or `{:reply, {:error, reason}, socket}` from `handle_in`** — don't silently drop messages

---

## Socket Authentication

Channels bypass the Plug pipeline, so session-based auth doesn't work. Use token-based authentication.

### Generating Tokens (Server Side)

```elixir
# In a controller or LiveView — generate a token for the current user
defmodule MyAppWeb.UserAuth do
  def generate_socket_token(conn) do
    Phoenix.Token.sign(conn, "user socket", conn.assigns.current_user.id)
  end
end

# In your layout or root template
<script>
  window.userToken = "<%= Phoenix.Token.sign(@conn, "user socket", @current_user.id) %>"
</script>
```

### Verifying Tokens (Socket)

```elixir
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", MyAppWeb.RoomChannel
  channel "notifications:*", MyAppWeb.NotificationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # Tokens expire after 2 weeks by default — configure max_age
    case Phoenix.Token.verify(socket, "user socket", token, max_age: 1_209_600) do
      {:ok, user_id} ->
        {:ok, assign(socket, :user_id, user_id)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.user_id}"
end
```

**Bad:**
```elixir
# No authentication — anyone can connect
def connect(_params, socket, _connect_info) do
  {:ok, socket}
end
```

---

## Topic Authorization

Verify in `join/3` that the user is allowed to access the topic.

```elixir
defmodule MyAppWeb.RoomChannel do
  use MyAppWeb, :channel

  @impl true
  def join("room:" <> room_id, _payload, socket) do
    user_id = socket.assigns.user_id

    if Rooms.member?(room_id, user_id) do
      {:ok, assign(socket, :room_id, room_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end
end
```

**Bad:**
```elixir
# No authorization — any authenticated user can join any room
def join("room:" <> room_id, _payload, socket) do
  {:ok, assign(socket, :room_id, room_id)}
end
```

---

## Channel Message Patterns

### Client-to-Server (handle_in)

Always reply so the client knows the result.

```elixir
@impl true
def handle_in("new_msg", %{"body" => body}, socket) do
  user_id = socket.assigns.user_id
  room_id = socket.assigns.room_id

  case Chat.create_message(room_id, user_id, body) do
    {:ok, message} ->
      broadcast!(socket, "new_msg", %{
        id: message.id,
        body: message.body,
        user_id: message.user_id,
        inserted_at: message.inserted_at
      })
      {:reply, :ok, socket}

    {:error, changeset} ->
      {:reply, {:error, %{errors: format_errors(changeset)}}, socket}
  end
end
```

**Bad:**
```elixir
# No reply — client doesn't know if message was received
def handle_in("new_msg", %{"body" => body}, socket) do
  broadcast!(socket, "new_msg", %{body: body})
  {:noreply, socket}
end
```

### Server-to-Client (push)

Send a message to a specific client, not everyone.

```elixir
# Push to this specific client only
push(socket, "typing", %{user_id: other_user_id})

# Broadcast to all clients on the topic (including sender)
broadcast!(socket, "new_msg", payload)

# Broadcast to all clients except the sender
broadcast_from!(socket, "user_joined", %{user_id: user_id})
```

### External Messages (handle_info)

For messages from PubSub, timers, or other processes.

```elixir
@impl true
def handle_info({:new_notification, notification}, socket) do
  push(socket, "notification", %{
    title: notification.title,
    body: notification.body
  })
  {:noreply, socket}
end
```

---

## Topic Naming Conventions

```elixir
# Resource-specific — one room
"room:42"

# User-scoped — all notifications for a user
"notifications:user_123"

# Collection-wide — all public updates
"updates:all"

# Subtopic — specific channel within a room
"room:42:typing"
```

**Pattern match in join to extract IDs:**
```elixir
def join("room:" <> room_id, _payload, socket) do
  # room_id is a string — parse if needed
  room_id = String.to_integer(room_id)
  # ...
end
```

---

## Presence Tracking

Use `Phoenix.Presence` for tracking who is online. It handles distributed nodes automatically.

### Setup

```elixir
# lib/my_app_web/channels/presence.ex
defmodule MyAppWeb.Presence do
  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub
end
```

### Tracking in a Channel

```elixir
defmodule MyAppWeb.RoomChannel do
  use MyAppWeb, :channel
  alias MyAppWeb.Presence

  @impl true
  def join("room:" <> room_id, _payload, socket) do
    send(self(), :after_join)
    {:ok, assign(socket, :room_id, room_id)}
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Track this user's presence
    {:ok, _} = Presence.track(socket, socket.assigns.user_id, %{
      online_at: inspect(System.system_time(:second)),
      typing: false
    })

    # Send current presence state to the joining client
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end
end
```

### Updating Presence Metadata

```elixir
@impl true
def handle_in("typing", %{"typing" => typing}, socket) do
  Presence.update(socket, socket.assigns.user_id, fn meta ->
    Map.put(meta, :typing, typing)
  end)
  {:reply, :ok, socket}
end
```

---

## When to Use Channels vs LiveView vs PubSub

| Feature | Channels | LiveView | PubSub |
|---------|----------|----------|--------|
| **Client** | Any (mobile, SPA, IoT) | Browser only | Server-side only |
| **Protocol** | WebSocket + custom | WebSocket + HTML | Erlang messages |
| **Rendering** | Client renders | Server renders | No rendering |
| **Use when** | Non-browser clients, custom protocols | Browser UI with real-time | Inter-process communication |

**Choose Channels when:**
- Mobile apps need real-time features
- SPA frontend (React, Vue) needs WebSocket communication
- External services need bidirectional communication
- You need a custom binary protocol

**Choose LiveView when:**
- Browser-based UI with real-time updates
- Server-rendered HTML is acceptable
- You want to avoid writing JavaScript

**Choose PubSub when:**
- Server-side inter-process communication only
- LiveView components need to communicate
- Background jobs need to notify the web layer

---

## Testing Channels

```elixir
defmodule MyAppWeb.RoomChannelTest do
  use MyAppWeb.ChannelCase

  setup do
    user = user_fixture()
    room = room_fixture(members: [user])
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "user socket", user.id)
    {:ok, socket} = connect(MyAppWeb.UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(socket, "room:#{room.id}", %{})

    %{socket: socket, user: user, room: room}
  end

  test "new_msg broadcasts to room", %{socket: socket} do
    ref = push(socket, "new_msg", %{"body" => "hello"})

    assert_reply ref, :ok
    assert_broadcast "new_msg", %{body: "hello"}
  end

  test "new_msg with invalid data returns error", %{socket: socket} do
    ref = push(socket, "new_msg", %{"body" => ""})

    assert_reply ref, :error, %{errors: _}
  end

  test "unauthorized user cannot join room" do
    other_user = user_fixture()
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "user socket", other_user.id)
    {:ok, socket} = connect(MyAppWeb.UserSocket, %{"token" => token})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "room:#{room.id}", %{})
  end

  test "presence is tracked on join", %{socket: socket, user: user} do
    assert %{^(to_string(user.id)) => %{metas: [%{online_at: _}]}} =
             MyAppWeb.Presence.list(socket)
  end
end
```

---

See `phoenix-pubsub-patterns` skill for server-side PubSub patterns.
See `phoenix-liveview-essentials` skill for LiveView real-time patterns.
See `testing-essentials` skill for comprehensive testing patterns.
